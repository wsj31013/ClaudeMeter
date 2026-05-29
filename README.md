# ClaudeMeter

macOS 메뉴바에서 Claude Code 사용량(5시간 / 7일 한도)을 실시간으로 모니터링하는 앱입니다.

---

## Requirements

| 항목 | 최소 요구 사항 |
|---|---|
| macOS | **14 Sonoma** 이상 |
| CPU | Apple Silicon (arm64) 또는 Intel (x86_64) |
| 사전 조건 | [Claude Code](https://claude.ai/code) 설치 및 로그인 완료 |

> Claude Code가 설치되어 있지 않거나 로그인하지 않은 상태에서는 동작하지 않습니다.

---

## Installation

### 방법 1 — 릴리즈 다운로드 (권장)

1. [Releases](../../releases/latest) 페이지에서 `ClaudeMeter-x.x.x-universal.zip` 다운로드
2. 압축 해제 후 `ClaudeMeter.app`을 `/Applications`로 이동
3. **최초 실행 시 Gatekeeper 우회 필요** (아래 참고)

#### Gatekeeper 우회

Apple 개발자 인증서 없이 빌드된 앱이므로 macOS가 최초 실행을 차단합니다.  
터미널에서 아래 명령어를 한 번만 실행하면 이후 정상 실행됩니다.

```bash
xattr -cr /Applications/ClaudeMeter.app
open /Applications/ClaudeMeter.app
```

또는 Finder에서 우클릭 → **열기** → 열기 버튼 클릭

---

### 방법 2 — 소스에서 직접 빌드

**요구 사항:** Xcode Command Line Tools

```bash
# 설치 확인
xcode-select -p

# 없다면 설치
xcode-select --install
```

```bash
git clone https://github.com/<your-username>/claude-meter.git
cd claude-meter/ClaudeMeter

# 빌드 (유니버설 바이너리 + zip 생성)
bash build_app.sh 1.0.0

# 설치
cp -r ClaudeMeter.app /Applications/
```

---

## How It Works

Claude Code는 로그인 시 OAuth 토큰을 macOS 키체인(`Claude Code-credentials`)에 저장합니다.  
ClaudeMeter는 해당 키체인 항목을 읽어 Anthropic API에 사용량을 조회합니다.

- 사용량은 **5분마다** 자동 갱신
- 토큰 만료 시 **자동으로 갱신** (refresh token 사용)
- refresh token까지 만료된 경우 Claude Code에서 재로그인 필요

---

## Dependencies

외부 Swift 패키지 의존성 없음. 사용 프레임워크:

| 프레임워크 | 용도 |
|---|---|
| SwiftUI | 메뉴바 UI |
| AppKit | NSStatusItem, NSPopover |
| Security | Keychain 접근 |
| Foundation | 네트워크(URLSession), JSON 파싱 |

---

## Permissions

앱 샌드박스(App Sandbox) 적용 상태이며 다음 권한만 사용합니다.

| 권한 | 이유 |
|---|---|
| `network.client` | Anthropic API 호출 |
| `keychain-access-groups` | Claude Code 인증 토큰 읽기/갱신 |

---

## License

MIT
