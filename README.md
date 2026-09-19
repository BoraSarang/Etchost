# Etchost (호스트갈이)

A macOS menu-bar app that manages `/etc/hosts` as reusable **profiles + fragments**, applies them with one click, and exposes local ports to the public internet via **cloudflared quick tunnels**.

## Features

- **Profiles & Fragments** — Keep hosts entries as composable building blocks. Toggle fragments on/off per profile, get a real-time composited preview, and apply on demand.
- **One-click apply** — Switch the active profile and write `/etc/hosts` from a single password prompt. Stale detection via content fingerprinting tells you exactly which profiles need re-applying.
- **Auto backup** — `/etc/hosts` is backed up before every write, with configurable retention count.
- **Port scanning** — Quick TCP scans against localhost/LAN targets, including HTTP service fingerprinting.
- **Cloudflare tunnels** — Spawn a `cloudflared` quick tunnel straight from a scan result (public URL auto-copied), with automatic restart when your local IP changes.
- **Localized** — Korean/English UI (system-following or explicit language setting) via an i18n-key architecture.

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon (arm64)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — the Xcode project is generated from `project.yml`
- `cloudflared` (optional) — only needed for the tunnel feature. Installed automatically into `~/.etchost/bin` on first tunnel use.

## Build & Test

```sh
./build_and_run.sh build   # generate project + build Debug
./build_and_run.sh test    # run Swift Testing suites (EtchostKit)
./build_and_run.sh lint    # SwiftLint
./build_and_run.sh run     # launch the built app
./build_and_run.sh install # copy into /Applications
./build_and_run.sh clean   # remove build/ + generated .xcodeproj
```

## Project layout

```
Sources/EtchostApp      macOS app (SwiftUI, menu-bar popover + main window)
Sources/EtchostKit      Framework + Swift Package (models, stores, services)
Resources/i18n          ko.json / en.json — single source of truth for UI strings
Scripts/sync_localization.py — generates Localizable.strings from the JSONs
Tests/EtchostKitTests   Swift Testing suites (49 tests / 16 suites)
```

| Bundle ID | `com.borasarang.etchost` |
| --- | --- |
| Localization | Korean, English |
| License | MIT |

## License

[`LICENSE`](LICENSE) — released under the MIT license.

---

## 한국어

맥 메뉴바에서 `/etc/hosts`를 **프로필·프래그먼트** 단위로 조합·토글·원클릭 적용하고, `cloudflared` quick tunnel로 로컬 포트를 공개 도메인에 연결하는 macOS 앱입니다.

- **프로필/프래그먼트**: hosts 항목을 구성요소 단위로 조합·토글, 실시간 합성 미리보기와 원클릭 적용
- **안전한 적용**: 쓰기 전 `/etc/hosts` 자동 백업(보존 개수 설정), 지문 비교로 "적용 필요" 자동 판정
- **포트 스캔**: localhost/LAN 대상 빠른 TCP 스캔(HTTP 핑거프린트 포함)
- **Cloudflare 터널**: 스캔 결과에서 바로 quick tunnel 생성, IP 변경 감지 시 자동 재시작
- **다국어**: 한국어/영어 UI (시스템 설정 따르기 또는 명시적 언어 선택)

### 빌드

```sh
./build_and_run.sh build   # 프로젝트 생성 + Debug 빌드
./build_and_run.sh test    # Swift Testing 실행
./build_and_run.sh run     # 앱 실행
```

최소 지원: macOS 26 (arm64). XcodeGen으로 프로젝트를 생성합니다. `cloudflared`는 터널 기능에서만 필요하며, 첫 사용 시 `~/.etchost/bin`에 자동 설치됩니다.