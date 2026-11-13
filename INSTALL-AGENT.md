# ThruRNDIS-Wi-Fi 설치 가이드 (AI 에이전트용)

Claude, Astra 같은 AI 에이전트가 사용자의 맥에 ThruRNDIS-Wi-Fi 를 설치하고 처음 설정할 때 따르는 절차입니다. 사람이 읽는 설명은 [README](README.md) 에 있습니다. 이 문서는 특정 에이전트의 기능에 기대지 않습니다. 셸을 쓸 수 없는 에이전트는 명령을 사용자에게 보여 주고 결과를 받아 판단합니다.

## 무엇을 설치하나

- **ThruRNDIS** (별도 앱, Afcoo): 작은 Linux VM 에 USB 장치를 넘겨 처리합니다. 이 프로젝트는 ThruRNDIS 를 고치지 않고, ThruRNDIS 의 "수동 VM 자산" 설정만 바꿉니다.
- **ThruRNDIS-Wi-Fi** (메뉴 막대 앱): ThruRNDIS 가 Wi-Fi 드라이버가 든 VM 이미지로 부팅하게 하고, 메뉴에서 VM 의 Wi-Fi 를 조작합니다. VM 이미지는 앱 안에 들어 있습니다.
- **라우팅 도우미** (root launchd 데몬): 지정한 대역만 USB Wi-Fi 동글로 보내고, ThruRNDIS 의 연결(`bond0`, `192.168.100.2`)이 맥의 기본 경로가 되지 않게 막습니다.

결과적으로 맥 내장 Wi-Fi 는 인터넷에 그대로 두고, 동글로는 다른 Wi-Fi(인터넷 없는 장비망 등)에 동시에 붙습니다.

## 에이전트가 지킬 것

### 사용자만 할 수 있는 일

다음은 에이전트가 대신하지 않습니다. 화면을 조작할 수 있는 에이전트도 마찬가지입니다. 무엇을 눌러야 하는지 알려 주고 끝났다고 할 때까지 기다립니다.

| 일 | 언제 |
| --- | --- |
| 관리자 암호 입력 | 라우팅 도우미 설치 · 업데이트 · 제거, `brew` 가 물을 때 |
| Wi-Fi 비밀번호 입력 | 메뉴에서 네트워크에 연결할 때. 비밀번호를 대화 · 파일 · 명령줄에 남기지 않습니다 |
| macOS · ThruRNDIS 승인 창 | "확인되지 않은 개발자" 의 **그래도 열기**, 로컬 네트워크 접근 허용, ThruRNDIS 온보딩(Privileged Helper), ThruRNDIS 의 USB 연결 확인, ThruRNDIS 종료 확인 |
| 동글 꽂기 · 뽑기 | 물리 동작 |

### 사용자에게 먼저 묻고 할 일

- 소프트웨어 설치 (`brew install`, 앱을 `/Applications` 에 넣거나 바꾸기), 파일 내려받기
- 메뉴의 **ThruRNDIS 에 적용** · **VM 이미지 업데이트** · **원래 이미지로** — ThruRNDIS 를 다시 시작하므로 쓰고 있던 ThruRNDIS 연결(휴대폰 테더링 등)이 끊깁니다
- 라우팅 도우미 설치 · 제거, 저장된 네트워크 · 키체인 항목 삭제

### 하지 않을 일

- `route add` / `route delete` 로 맥 경로를 손으로 바꾸지 않습니다. 경로는 도우미가 관리합니다. 특히 `route add -host 192.168.100.1 -interface bond0` 는 VM 과의 통신을 끊습니다.
- `defaults write com.afcoo.thrurndis ...` 로 ThruRNDIS 설정을 손으로 바꾸지 않습니다. 메뉴의 **ThruRNDIS 에 적용** 이 백업과 함께 바꿉니다.
- 앱의 격리 속성(quarantine)을 지워 Gatekeeper 경고를 건너뛰지 않습니다. 사용자가 **그래도 열기** 를 누르게 합니다.
- VM 제어 API 의 `connect` · `disconnect` · `restart` 를 직접 부르지 않습니다. 메뉴로 합니다. 읽기용 `status` · `diag` 는 괜찮습니다.
- 동글로 작은 패킷을 고율로 몰아치는 시험을 하지 않습니다. 맥의 USB 전달이 동글 송신을 멈추게 할 수 있습니다.

아래 "확인" 명령은 모두 읽기 전용이라 묻지 않고 실행해도 됩니다.

### 사용자에게 받을 정보

- 동글로 붙을 Wi-Fi 의 SSID (비밀번호는 사용자가 메뉴에 직접 입력)
- 그 망에 DHCP 가 있는지. 없으면 고정 IP · 서브넷 · 게이트웨이, 필요하면 DNS
- 그 망 안의 다른 라우터 너머에 있는 대역(추가 경로)과 그 게이트웨이
- 동글 망 대역 말고도 동글로 보낼 대역이 있는지 (메뉴의 "추가 대역")

## 1. 사전 확인

```sh
sw_vers -productVersion        # 27 이상이어야 합니다 (ThruRNDIS 요구 사항)
uname -m                       # arm64 (Apple Silicon) 이어야 합니다
ls -d /Applications/ThruRNDIS.app && defaults read /Applications/ThruRNDIS.app/Contents/Info CFBundleShortVersionString
ls -d /Applications/ThruRNDIS-Wi-Fi.app /Applications/VmWifi.app 2>/dev/null   # 이미 설치돼 있는지
command -v brew
```

- macOS 27 미만이거나 Intel 맥이면 설치할 수 없습니다. 사용자에게 알리고 멈춥니다.
- ThruRNDIS 는 0.4.1 에서 확인했습니다. 다른 버전이면 그 사실을 사용자에게 알리고 진행합니다.
- `VmWifi.app` 은 이 앱의 옛 이름입니다. 새 앱이 설정 · 저장된 네트워크를 옮겨 받으니, 새 앱이 동작하는 것을 확인한 뒤 지울지 사용자에게 묻습니다.

동글의 USB ID 를 확인합니다. 동글을 ThruRNDIS 로 넘기면 맥의 USB 목록에서 사라지니, 넘기기 전에 봅니다.

```sh
system_profiler SPUSBDataType | grep -B2 -A8 -i 'wireless\|wlan\|802.11\|realtek\|mediatek\|ralink\|atheros'
```

`Vendor ID: 0x0bda` · `Product ID: 0xb812` 처럼 나오면 USB ID 는 `0bda:b812` 입니다. README 의 "지원 동글" 표나 [`vm/drivers.conf`](vm/drivers.conf) 의 칩과 견줍니다. 실제 동글로 확인한 것은 `0bda:b831`(RTL8851BU) 과 `0bda:b812`(RTL8822BU) 입니다. 칩을 모르면 일단 진행합니다. 지원하지 않으면 동글을 넘긴 뒤 메뉴에 드라이버가 없다는 안내가 뜹니다.

## 2. ThruRNDIS 설치와 첫 실행

없으면 사용자에게 묻고 설치합니다.

```sh
brew install --cask afcoo/tap/thrurndis
open -a ThruRNDIS
```

처음 실행하면 ThruRNDIS 온보딩이 Privileged Helper 승인을 요청합니다. 사용자가 마치게 합니다. 온보딩을 마치기 전에는 다음 단계가 동작하지 않습니다.

## 3. 앱 설치

사용자에게 묻고 최신 릴리스를 받습니다. 저장소는 `afy0817/ThruRNDIS-Wi-Fi` 입니다.

```sh
DIR=$(mktemp -d)
curl -fL -o "$DIR/ThruRNDIS-Wi-Fi.zip" \
    https://github.com/afy0817/ThruRNDIS-Wi-Fi/releases/latest/download/ThruRNDIS-Wi-Fi.zip
ditto -x -k "$DIR/ThruRNDIS-Wi-Fi.zip" "$DIR"
ls "$DIR/ThruRNDIS-Wi-Fi.app"
```

이미 설치돼 있으면 앱을 끈 뒤 바꿉니다. 저장된 네트워크와 설정은 앱 밖(UserDefaults · 키체인)에 있어 그대로 남습니다.

```sh
pkill -x ThruRNDISWiFi
rm -rf /Applications/ThruRNDIS-Wi-Fi.app
ditto "$DIR/ThruRNDIS-Wi-Fi.app" /Applications/ThruRNDIS-Wi-Fi.app
defaults read /Applications/ThruRNDIS-Wi-Fi.app/Contents/Info CFBundleShortVersionString
open /Applications/ThruRNDIS-Wi-Fi.app
```

- 공증받지 않은 앱이라 처음 열 때 "확인되지 않은 개발자" 경고가 뜹니다. 사용자가 **시스템 설정 → 개인정보 보호 및 보안** 아래쪽의 **그래도 열기** 를 누르게 합니다.
- 로컬 네트워크 접근을 물으면 **허용** 하게 합니다. 앱은 VM(`192.168.64.x`)과 이 권한으로 통신합니다. 거부했으면 **시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크** 에서 ThruRNDIS-Wi-Fi 를 켭니다.
- 메뉴 막대에 Wi-Fi 아이콘이 생기면 됩니다. `pgrep -x ThruRNDISWiFi` 로 실행 여부를 볼 수 있습니다.

이 문서는 저장소 main 기준입니다. 받은 릴리스가 더 오래됐으면 일부 메뉴(예: **VM 재시작**)나 안내 문구가 다를 수 있습니다.

## 4. 처음 설정

메뉴 막대의 앱 아이콘을 누르면 메뉴가 열립니다. 메뉴 위쪽 안내 칸이 지금 해야 할 일을 하나씩 보여 줍니다.

1. **ThruRNDIS 에 적용** — 안내 "ThruRNDIS 에 ThruRNDIS-Wi-Fi VM 이미지를 적용해야 합니다." 아래의 버튼입니다. 사용자에게 묻고 누릅니다.
   - ThruRNDIS 가 다시 시작하며 이 프로젝트의 VM 이미지로 부팅합니다. 원래 ThruRNDIS 설정은 백업됩니다.
   - ThruRNDIS 가 "USB 연결이 해제되고 네트워크 라우팅이 중지됩니다. 그래도 종료하시겠습니까?" 를 물으면 사용자가 **ThruRNDIS 종료** 를 누르게 합니다. 60초 안에 답이 없으면 "ThruRNDIS 가 종료되지 않았습니다." 로 실패하니, 그때는 다시 누릅니다.
   - 확인: `defaults read com.afcoo.thrurndis VMAssets.selectionSource` 가 `manual`, `defaults read com.afcoo.thrurndis VM.kernelCommandLine` 에 `thrurndis-wifi.token=` 이 있으면 적용된 것입니다.
2. **동글 넘기기** — 사용자가 동글을 꽂고, 메뉴 막대의 **가상 머신 액세서리** 에서 동글을 **ThruRNDIS** 로 넘깁니다. ThruRNDIS 의 USB 연결 확인 창이 뜨면 승인합니다.
   - ThruRNDIS 설정의 **USB 기기** 에서 이 동글의 **자동 연결** 을 켜 두라고 권합니다. 동글 송신이 막혀 앱이 VM 을 다시 시작할 때, 이게 켜져 있어야 동글이 저절로 다시 붙습니다.
   - 메뉴에 검색 목록과 "맥 라우팅" 칸이 나오면 동글이 잡힌 것입니다.
   - "USB 장치 xxxx:yyyy 를 맡을 드라이버가 VM 에 없습니다." 가 뜨면 지원하지 않는 동글입니다. 사용자에게 알리고 멈춥니다. 드라이버를 더하려면 Docker 로 VM 이미지를 다시 빌드해야 합니다 (README "다른 동글 쓰기").
3. **라우팅 도우미 설치** — "맥 라우팅" 칸의 **설치 (관리자 암호)**. 사용자가 관리자 암호를 입력합니다.
   - 확인: `ls /Library/LaunchDaemons/io.github.afy0817.thrurndis-wifi.routed.plist /usr/local/libexec/thrurndis-wifi-routed` 가 둘 다 있고, 메뉴에 `도우미 설치됨` 이 보이면 됩니다.
4. **연결** — **검색** → 네트워크 행을 누르거나 **연결** → 사용자가 비밀번호를 입력합니다. 숨김 네트워크는 **다른 네트워크(숨김)…** 에서 SSID 를 넣습니다.
   - DHCP 가 없는 망이면 비밀번호 칸 아래 **고정 IP 직접 입력…** 에서, 또는 연결한 뒤 **저장된 네트워크 → IP** 에서 주소를 넣습니다. 칸: IP 주소, 서브넷 마스크(`255.255.255.0` · `/24` · `24`), 게이트웨이(선택), DNS(선택, 쉼표로 구분, 3개까지), 추가 경로(선택, 대역 → 게이트웨이, 8줄까지).
   - 비밀번호가 틀리면 "<SSID>: 비밀번호가 틀린 것 같습니다" 와 함께 다시 입력 칸이 뜹니다.
5. **맥 라우팅 모드** — 기본 **지정 대역만** 을 그대로 둡니다. 동글 망 대역, 그 네트워크의 추가 경로, "추가 대역" 칸의 대역만 동글로 갑니다. **전체 트래픽** 은 모든 IPv4 를 동글로 보내므로 사용자가 원할 때만 고릅니다.

다 되면 메뉴 머리에 **연결됨**, 주소 줄에 **맥 연결 준비됨** 이 보입니다. 앱과 VM 을 다시 켜면 가장 최근 네트워크에 자동으로 붙습니다.

## 5. 확인

VM 상태 (읽기 전용 API):

```sh
TOKEN=$(defaults read io.github.afy0817.ThruRNDIS-Wi-Fi GuestToken)
LOG=$(ls -t ~/Library/Application\ Support/com.afcoo.thrurndis/Logs/*.log | head -1)
VM=$(grep -o 'Guest VZNAT network discovered: guest=[0-9.]*' "$LOG" | tail -1 | cut -d= -f2)
curl -s "http://$VM:8080/cgi-bin/api?action=status&token=$TOKEN"
```

| 필드 | 정상 | 아니면 |
| --- | --- | --- |
| `device` | `true` | 동글이 VM 에 없습니다. 4단계 2번 |
| `usb_unsupported` | `""` | 값이 있으면 그 USB ID 의 드라이버가 없습니다 |
| `wpa_state` | `COMPLETED` | 연결 중이거나 실패. `auth_error` 를 봅니다 (`wrong-key` · `auth-failed` · `not-found`) |
| `ipv4` | 주소 | 비었으면 DHCP 를 못 받았습니다. 고정 IP 를 넣습니다 |
| `ip_error` | `""` | `conflict` 면 같은 IP 를 쓰는 장치가 있습니다(`ip_conflict_mac`). 맥 내장 Wi-Fi 가 같은 망에 같은 IP 로 붙어 있을 때 흔합니다 |
| `route_ready` | `true` | 맥 쪽 연결 준비가 안 됐습니다 |
| `usb_recover` | `""` | `l1` · `l2` 는 VM 이 동글을 재설정하는 중, `failed` 는 VM 재시작이 필요합니다 |

맥 쪽 경로:

```sh
cat /var/run/thrurndis-wifi-routed.status        # primary= 가 bond 가 아니어야 합니다 (보통 en0)
netstat -rn -f inet | grep 192.168.100.1          # 동글로 가는 경로
route -n get <장비 IP>                            # gateway: 192.168.100.1, interface: bond0 이면 동글로 갑니다
route -n get default                              # 맥 인터넷은 그대로 내장 Wi-Fi 여야 합니다
```

`curl` 이 응답하지 않으면 터미널 앱도 로컬 네트워크 권한을 물었는지 봅니다. 문제를 사용자에게 보고할 때는 진단 덤프가 도움이 됩니다.

```sh
curl -s "http://$VM:8080/cgi-bin/api?action=diag&token=$TOKEN"
```

## 6. 자주 막히는 곳

| 메뉴 안내 · 증상 | 할 일 |
| --- | --- |
| ThruRNDIS 가 필요합니다. | 2단계 |
| ThruRNDIS 가 실행 중이 아닙니다. | **ThruRNDIS 실행** 을 누르거나 `open -a ThruRNDIS` |
| VM 이 아직 실행되지 않았습니다. | 동글을 ThruRNDIS 로 넘깁니다 (4단계 2번) |
| VM 은 실행 중이지만 동글이 연결되지 않았습니다. | 동글을 다시 넘깁니다 |
| USB 장치 xxxx:yyyy 를 맡을 드라이버가 VM 에 없습니다. | 지원하지 않는 동글입니다 |
| ThruRNDIS 가 종료되지 않았습니다. | ThruRNDIS 의 종료 확인 창에서 **ThruRNDIS 종료** 를 누르게 하고 다시 시도합니다 |
| VM 토큰이 맞지 않습니다. | **원래 이미지로** → **ThruRNDIS 에 적용** (사용자에게 묻고) |
| 앱에 새 VM 이미지가 들어 있습니다. | **VM 이미지 업데이트** (사용자에게 묻고, ThruRNDIS 가 다시 시작합니다) |
| 맥 연결 준비 중 이 오래 감 | DHCP 가 없는 망입니다. 고정 IP 를 넣습니다 |
| 맥의 기본 경로가 동글 쪽(...)으로 넘어가 있습니다. | 도우미를 설치하거나 업데이트합니다. 맥 인터넷이 끊긴 원인입니다 |
| <대역> 는 맥에 이미 <게이트웨이> 경로가 있어 동글로 돌리지 않았습니다. | 사용자가 예전에 손으로 넣은 경로가 있습니다. `route -n get` 으로 보여 주고, 지울지는 사용자가 정합니다 |
| 대역 형식이 잘못되었습니다. | "추가 대역" 칸을 `10.0.0.0/24, 192.168.50.0/24` 형식으로 고칩니다. 틀린 동안은 추가 대역이 하나도 동글로 가지 않습니다 |
| 송신 지연 · 동글 재설정 중 · VM 재시작 중 | VM 이 맥의 USB 전달 문제를 감지해 스스로 복구하는 중입니다. 기다립니다. 자동 재시작 횟수(30분에 1회, 24시간에 4회)를 넘으면 메뉴의 **VM 재시작** 을 누릅니다 |
| <SSID> 에 자동으로 연결하지 못했습니다(…). | **저장된 네트워크** 에서 **연결** 을 누릅니다 |
| 신호가 약함 (-70 dBm 보다 약함) | 동글을 USB 연장선으로 맥에서 떨어뜨리거나 AP 쪽으로 옮깁니다 |

## 7. 업데이트

1. 3단계처럼 새 릴리스로 앱을 바꿉니다.
2. 메뉴에 "앱에 새 VM 이미지가 들어 있습니다." 가 뜨면 사용자에게 묻고 **VM 이미지 업데이트** 를 누릅니다. 앱과 VM 은 따로 갱신되므로 이걸 누르기 전까지는 옛 VM 이 돕니다.
3. "맥 라우팅" 칸에 `도우미 업데이트 필요` 가 보이면 **업데이트 (관리자 암호)** — 사용자가 암호를 입력합니다.

## 8. 되돌리기와 제거

사용자가 원할 때만 합니다.

1. 메뉴 아래쪽 **원래 이미지로** — ThruRNDIS 설정을 적용 전으로 되돌립니다.
2. "맥 라우팅" 칸의 **제거** (관리자 암호) — 데몬과 데몬이 넣은 경로를 지웁니다.
3. 앱을 끄고 `/Applications/ThruRNDIS-Wi-Fi.app` 을 휴지통에 넣습니다.
4. 남는 데이터: `~/Library/Application Support/ThruRNDIS-Wi-Fi`, 설정 도메인 `io.github.afy0817.ThruRNDIS-Wi-Fi`, 키체인의 `ThruRNDIS-Wi-Fi: <SSID>` 항목. 저장된 비밀번호가 사라지므로 지울지는 사용자가 정합니다.
