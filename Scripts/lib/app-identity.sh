#!/usr/bin/env bash

# 앱 이름과 배포 식별자의 단일 정의. 표시 이름을 바꿀 때는 여기와 app_identity.py를 함께 고친다.
# bundle identifier는 이름을 바꿔도 유지하는 저장 식별자다(계정, Keychain, 권한, 업데이트 경로).
# 이 파일을 source하는 배포 스크립트가 쓰는 값이다.
# shellcheck disable=SC2034
APP_PRODUCT_NAME="ClaudeUsage"
APP_PROD_DISPLAY_NAME="$APP_PRODUCT_NAME"
APP_STAGING_DISPLAY_NAME="${APP_PRODUCT_NAME}-stg"
APP_PROD_BUNDLE_IDENTIFIER="com.seongmin.ClaudeUsage"
APP_STAGING_BUNDLE_IDENTIFIER="com.seongmin.ClaudeUsage.staging"
APP_RELEASE_ZIP_NAME="${APP_PRODUCT_NAME}.zip"
APP_RELEASE_DMG_NAME="${APP_PRODUCT_NAME}.dmg"
