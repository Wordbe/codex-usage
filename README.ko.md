<p align="center">
  <img src="docs/assets/codexusage-icon.svg" width="112" alt="CodexUsage 아이콘">
</p>

<h1 align="center">CodexUsage</h1>

CodexUsage는 Codex 사용량을 퍼센트와 막대로 보여주는 macOS 메뉴바 앱입니다.

English README: [README.md](README.md) · [최신 DMG 다운로드](https://github.com/Wordbe/codex-usage/releases/latest/download/CodexUsage.dmg) · [MIT License](LICENSE)

## 다운로드 및 설치

1. 최신 [CodexUsage.dmg](https://github.com/Wordbe/codex-usage/releases/latest/download/CodexUsage.dmg)를 다운로드합니다.
2. DMG를 엽니다.
3. DMG 안의 `READ BEFORE INSTALL - Open Anyway Guide.txt`를 먼저 읽습니다.
4. `CodexUsage.app`을 더블클릭합니다.

macOS가 `"CodexUsage" Not Opened`를 보여주면 **시스템 설정 > 개인정보 보호 및 보안**에서 CodexUsage의 **그래도 열기**를 누르고 `CodexUsage.app`을 다시 더블클릭하세요.

DMG에서 처음 실행하면 CodexUsage가 스스로 `~/Applications/CodexUsage.app`로 복사되고 설치된 앱을 실행합니다. 로그인 항목을 만들고 CLI를 `~/.codexusage/bin/codexusage`에 연결합니다.

CodexUsage는 계정 전환을 켜지 않는 한 Codex `config.toml`이나 Codex status line을 수정하지 않습니다.

## 오픈소스

CodexUsage는 [MIT License](LICENSE)로 공개된 오픈소스 프로젝트입니다.

저장소에는 다음이 포함됩니다.

- macOS 메뉴바 앱의 Swift 소스 코드
- DMG 빌드 및 GitHub 릴리즈 스크립트
- SVG 제품 아이콘: [docs/assets/codexusage-icon.svg](docs/assets/codexusage-icon.svg)
- 영어/한국어 설치 문서
- DMG에서 앱 더블클릭만으로 설치되는 self-install 동작
- 선택 기능인 `codex-account` 도우미: [tools/codex-account](tools/codex-account)

이슈와 Pull Request는 [Wordbe/codex-usage](https://github.com/Wordbe/codex-usage)에서 받을 수 있습니다.

보안 문제는 공개 이슈 대신 비공개로 제보해주세요. [SECURITY.md](SECURITY.md)를 참고하세요.

## CLI

```bash
~/.codexusage/bin/codexusage status
~/.codexusage/bin/codexusage status --json
~/.codexusage/bin/codexusage status --refresh
~/.codexusage/bin/codexusage status --diagnose
```

GUI 앱이 Codex를 찾지 못하면 다음을 설정하세요.

```bash
export CODEXUSAGE_CODEX_PATH="$(command -v codex)"
```

## 계정 전환 (선택)

계정 전환은 기본적으로 꺼져 있습니다. 메뉴에서 **Enable Account Switching...**을
누르면 앱에 포함된 `codex-account` 도우미가 `~/.codexusage/bin/codex-account`에
설치됩니다. Python 3.11 이상이 필요합니다(예: `brew install python`).
특정 Python을 쓰려면 `CODEXUSAGE_PYTHON`을 지정하세요.

켜면 메뉴에 저장된 계정과 마지막으로 확인한 5시간, 주간 사용량이 표시됩니다.
계정을 누르면 다음 순서로 전환합니다.

1. ChatGPT 앱을 종료합니다. 처음 한 번 macOS가 CodexUsage의 ChatGPT 제어 권한을 묻습니다.
2. 현재 로그인을 보관하고 선택한 계정을 `~/.codex/auth.json`에 기록합니다.
3. ChatGPT 내장 Codex로 계정을 확인하고, 실패하면 되돌린 뒤 ChatGPT를 다시 엽니다.

**Add Account...**는 터미널에서 `codex-account add`(기기 코드 로그인)를 실행합니다.
로그인과 백업은 소유자 전용 권한으로 `~/.codex-accounts`에 저장됩니다.
인증 정보가 들어 있으니 공유하지 마세요. 전환 시 `~/.codex/config.toml`에
`cli_auth_credentials_store = "file"`을 설정하며 기존 파일은 백업합니다.

PATH의 `python3`가 3.11 이상이면 도우미를 CLI로도 사용할 수 있습니다.

```bash
~/.codexusage/bin/codex-account
~/.codexusage/bin/codex-account list
~/.codexusage/bin/codex-account switch <이름>
~/.codexusage/bin/codex-account add
```

**Disable Account Switching...**은 도우미를 제거합니다. `~/.codex-accounts`의
저장된 로그인은 유지됩니다.

## 데이터와 동기화

CodexUsage는 ChatGPT 앱의 `~/.codex/auth.json` 인증을 따라갑니다.
조회 프로세스에는 `CODEX_HOME=~/.codex`를 명시하므로 실행한 터미널의 다른
`CODEX_HOME` 설정에 영향을 받지 않습니다. 설치된 ChatGPT 앱의 내장 Codex를
우선 사용하며 `CODEXUSAGE_CODEX_PATH`로 실행 파일을 지정할 수 있습니다.

새 조회마다 같은 app-server 연결에서 다음 API를 호출합니다.

```text
account/read
account/rateLimits/read
```

메뉴와 CLI에 이메일, 플랜, 갱신 시각을 표시합니다. 메뉴바에는 300분 구간의
사용량을 표시하며, 해당 구간이 없으면 `0%` 대신 `--%`를 보여줍니다.
서버가 10080분 구간을 제공하면 주간 사용량도 메뉴에 표시해요.

캐시는 사용자와 워크스페이스 식별자를 해시하여 분리합니다.

```text
~/.codexusage/cache/accounts/<identity-hash>.json
```

인증 토큰은 캐시에 저장하지 않으며, 이전 공용 캐시는 재사용하지 않습니다.
API 키와 키체인에만 저장된 인증은 이 파일 기반 계정 추적에서 지원하지 않습니다.
사용량 추적만으로는 인증 설정을 변경하지 않아요.

정책:

- 사용량은 60초마다 동기화하고 캐시 TTL은 30초입니다.
- 계정 변경은 메뉴를 열어둔 상태에서도 2초마다 확인합니다.
- 계정이 바뀌면 이전 표시를 지우고 즉시 조회하며 CodexUsage 재시작은 필요 없습니다.
- 이전 계정의 늦은 응답은 버리고, 캐시 대체도 동일 사용자와 워크스페이스로 제한합니다.
- `status --refresh`는 새 조회를 수행합니다. 실패하면 같은 계정의 최대 6시간 이전 캐시를 오래된 데이터로 명시해 반환할 수 있으며, 메뉴바에서는 오래된 퍼센트를 숨깁니다.
- 세션 로그는 진단용으로만 사용하며 기본 사용량 표시에는 사용하지 않습니다.
- `status --diagnose`는 API, 캐시, 세션을 비교합니다. 세션은 다른 계정의 기록일 수 있어요.

## 검증

```bash
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
```

Python 테스트는 Python 3.11 이상이 필요하며, `swift test`로 빌드된 디버그 실행 파일과
가짜 app-server, 가짜 계정 로그인을 사용합니다.
실제 인증 정보나 네트워크를 사용하지 않습니다.
