#!/usr/bin/env python3
import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


@dataclass(frozen=True)
class DownloadPolicy:
    connect_seconds: float = 10
    attempt_seconds: float = 120
    total_seconds: float = 240
    termination_seconds: float = 2


class DownloadTimeout(RuntimeError):
    pass


def stop_transfer(process, grace):
    deadline = time.monotonic() + grace
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=max(0, min(grace / 2, deadline - time.monotonic())))
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=max(0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired as error:
        raise DownloadTimeout("다운로드 프로세스의 종료를 확인하지 못했습니다.") from error


def run_transfer(command, environment, deadline, policy):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise DownloadTimeout("자산 다운로드 시간 제한을 초과했습니다.")
    process = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        return process.wait(timeout=min(policy.attempt_seconds, remaining))
    except subprocess.TimeoutExpired:
        stop_transfer(process, policy.termination_seconds)
        return 124
    except BaseException:
        stop_transfer(process, policy.termination_seconds)
        raise


def download_asset(repository, tag, asset, destination, token="", stale_index=False, policy=DownloadPolicy()):
    destination = Path(destination)
    if Path(asset).name != asset or destination.name != asset or destination.exists() or destination.is_symlink():
        raise ValueError("새 자산 다운로드 경로를 지정해 주세요.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    for key in ("GH_TOKEN", "GITHUB_TOKEN", "SCOPED_GITHUB_CLI_TOKEN"):
        environment.pop(key, None)
    deadline = time.monotonic() + policy.total_seconds
    with tempfile.TemporaryDirectory(prefix=".release-download-", dir=destination.parent) as temporary:
        root = Path(temporary)
        if not stale_index:
            github = root / "github"
            github.mkdir(mode=0o700)
            github_environment = dict(environment)
            if token:
                github_environment["GH_TOKEN"] = token
            result = run_transfer(
                ["gh", "release", "download", tag, "--repo", repository, "--pattern", asset, "--dir", str(github)],
                github_environment, deadline, policy)
            downloaded = github / asset
            if result == 0 and downloaded.is_file() and not downloaded.is_symlink():
                os.replace(downloaded, destination)
                return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise DownloadTimeout("자산 다운로드 시간 제한을 초과했습니다.")
        downloaded = root / asset
        result = run_transfer(
            ["curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
             "--proto-redir", "=https", "--connect-timeout", str(policy.connect_seconds),
             "--max-time", str(min(policy.attempt_seconds, remaining)), "--retry", "3", "--retry-all-errors",
             "--retry-max-time", str(max(1, int(remaining))), "--output", str(downloaded),
             f"https://github.com/{repository}/releases/download/{tag}/{asset}"],
            environment, deadline, policy)
        if result != 0 or not downloaded.is_file() or downloaded.is_symlink():
            if result == 124:
                raise DownloadTimeout("자산 다운로드 시간 제한을 초과했습니다.")
            raise RuntimeError("원격 자산을 내려받지 못했습니다.")
        os.replace(downloaded, destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--asset", required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--stale-index", action="store_true")
    args = parser.parse_args()
    token = sys.stdin.read(65537).strip()
    if len(token) > 65536:
        raise ValueError("GitHub 인증 입력이 올바르지 않습니다.")
    download_asset(args.repo, args.tag, args.asset, args.destination, token, args.stale_index)


if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"오류: {error}", file=sys.stderr)
        sys.exit(1)
