# 요금제별 사용량 응답 fixture

요금제에 따라 Claude와 Codex 사용량 응답에 없는 창, 깨진 창, 추가 한도가 있어도 화면에 무엇이
보여야 하는지를 고정한다. `PlanFixtureTests`가 파일마다 응답을 디코딩해 한도 행과 메뉴바 값을
`expected`와 비교한다. 표시 동작을 바꾸면 해당 fixture의 `expected`를 함께 고쳐야 하므로 변화가 diff로
드러난다.

## 파일 형식

- `meta.plans`: 이 응답 형태를 대표하는 요금제 값. `plan-values.json`에 있는 값만 쓴다
- `meta.source`: `measured`(실측 응답), `docs`(공식 문서와 공식 클라이언트 코드로 만든 형태),
  `assumed`(문서에 명시가 없어 가정한 형태). QA에서 신뢰도를 구분하는 기준이다
- `response`: 서버 응답. 실측본은 수치와 시각 외 계정 식별 정보를 남기지 않는다
- `expected.rows`: `제목=사용률` 목록. `expected.menuBar`: 메뉴바 퍼센트 표시 방식별 문자열.
  `expected.decodeError: true`면 디코딩이 실패해야 한다

파일 이름은 `claude-` 또는 `codex-`로 시작한다. 테스트 번들 리소스로 함께 복사되므로 이름이 겹치면
빌드가 실패한다. 같은 이유로 이 문서도 README가 아닌 이름을 쓴다.

## 요금제 목록

`plan-values.json`은 공식 소스에서 확인한 요금제 값과 출처, 확인 날짜를 담는다.
`Scripts/tests/test_plan_coverage.py`가 값마다 fixture가 있는지 배포 게이트에서 검사한다.
`python3 Scripts/tests/test_plan_coverage.py --refresh`는 설치된 Codex와 Claude Code 실행 파일에서
목록에 없는 요금제 후보 문자열을 알려준다. 후보가 실제 요금제인지는 공식 소스로 확인한 뒤에만
목록에 넣는다.
