# README_DEPLOY.md — 배포 가이드 (텔레메트리 차단 + Cloudflare Tunnel 외부 접근)

abtestSolution(GrowthBook fork)을 **포트 직접 개방 없이** Cloudflare Tunnel로 외부 노출하고,
**Cloudflare Access 이메일 게이트**로 본인만 접근하도록 구성하는 절차.

- front(3000) / api(3100) 둘 다 터널로 노출 → **호스트네임 2개**
- 텔레메트리 차단, 시크릿 분리, mongo 데이터 영속화는 `docker-compose.yml` + `.env`에 반영 완료
- 관련 보안 검토: [`SECURITY_AUDIT.md`](./SECURITY_AUDIT.md)

---

## 0. 사전 준비물

| 항목 | 확인 |
|---|---|
| Docker / Docker Compose | `docker --version`, `docker compose version` |
| cloudflared | `cloudflared --version` (없으면 §2) |
| Cloudflare 계정 + 연결된 도메인 | Access/named tunnel에 필수 |
| openssl | 시크릿 생성용 (이미 사용함) |

---

## 1. 시크릿 & compose (이미 적용됨)

`.env` (커밋 금지, `.gitignore`에 포함):
```env
JWT_SECRET=...            # openssl rand
ENCRYPTION_KEY=...        # openssl rand
MONGO_USERNAME=gbadmin
MONGO_PASSWORD=...        # openssl rand
DISABLE_TELEMETRY=true    # 텔레메트리 차단
APP_ORIGIN=https://<front-hostname>   # 터널 호스트네임으로 교체
API_HOST=https://<api-hostname>       # 터널 호스트네임으로 교체
```

직접 다시 생성하려면:
```bash
echo "JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 64)"
echo "ENCRYPTION_KEY=$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 64)"
echo "MONGO_PASSWORD=$(openssl rand -base64 32 | tr -d '\n/+=' | head -c 32)"
```

`docker-compose.yml` 주요 변경:
- `DISABLE_TELEMETRY=true`
- `JWT_SECRET` / `ENCRYPTION_KEY` / `APP_ORIGIN` / `API_HOST` 를 `.env`에서 주입
- mongo 자격증명 `.env`화 + **`mongodata:/data/db` 볼륨 영속화**
- 포트를 `127.0.0.1:3000` / `127.0.0.1:3100` 로 **루프백 바인딩** (직접 개방 금지, 터널만 노출)

검증:
```bash
docker compose config        # 변수 치환 확인
docker compose up -d          # 부팅
```

---

## 2. cloudflared 설치

macOS (Homebrew):
```bash
brew install cloudflared
# 또는 이미 설치됨: which cloudflared
```
Linux(.deb):
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb
```

---

## 3. Cloudflare 로그인 (브라우저 인증, 1회)

```bash
cloudflared tunnel login
```
브라우저가 열리면 → 본인 Cloudflare 계정 로그인 → **노출할 도메인(zone) 선택/인증**.
완료되면 `~/.cloudflared/cert.pem` 이 생성됨.

> 세션에서 직접 실행하려면 프롬프트에 `! cloudflared tunnel login` 입력.

---

## 4. 터널 생성 + DNS 라우트 + .env 갱신 (자동 스크립트)

호스트네임 2개를 정한다 (예시 — 실제 도메인으로 교체):
- front: `gb.example.com`
- api:  `gb-api.example.com`

제공된 헬퍼 스크립트 실행:
```bash
./cloudflared/setup-tunnel.sh gb.example.com gb-api.example.com abtest
```
이 스크립트가 자동으로 수행:
1. named tunnel `abtest` 생성 (있으면 재사용)
2. `cloudflared/config.yml` 작성 — ingress: front→`localhost:3000`, api→`localhost:3100`
3. 두 호스트네임 DNS 라우트(CNAME → 터널) 생성
4. `.env`의 `APP_ORIGIN` / `API_HOST` 를 해당 호스트네임으로 갱신

수동으로 하려면:
```bash
cloudflared tunnel create abtest
cloudflared tunnel route dns abtest gb.example.com
cloudflared tunnel route dns abtest gb-api.example.com
# cloudflared/config.yml 작성 (스크립트 참고)
```

---

## 5. 재기동 + 터널 실행

```bash
# APP_ORIGIN/API_HOST 변경 반영
docker compose up -d

# 터널 실행 (포그라운드 — 동작 확인)
cloudflared tunnel --config ./cloudflared/config.yml run abtest
```
상시 실행(서비스 등록):
```bash
# macOS (launchd) — config 경로를 쓰려면 기본 위치(~/.cloudflared/config.yml)로 심볼릭하거나 복사
sudo cloudflared service install
# 또는 백그라운드 실행
nohup cloudflared tunnel --config ./cloudflared/config.yml run abtest >/tmp/cloudflared.log 2>&1 &
```

---

## 6. Cloudflare Access 이메일 게이트 (본인만 허용)

Cloudflare Tunnel 자체엔 인증이 없으므로, **Zero Trust → Access**로 게이트를 건다.

대시보드 절차 (https://one.dash.cloudflare.com → Access → Applications):
1. **Add an application → Self-hosted**
2. Application 1:
   - Application domain: `gb.example.com` (front)
   - Session duration: 적절히 (예: 24h)
3. **Add policy**:
   - Action: **Allow**
   - Include → **Emails** → `seongwonyoung0311@gmail.com`
4. 저장
5. api 호스트네임(`gb-api.example.com`)에 대해 **동일하게 application + 정책** 1개 더 생성
   - (브라우저 외 API 호출이 필요하면 Service Token 정책을 추가로 둘 수 있음)

이후 두 URL 접속 시 Cloudflare 로그인 화면 → 허용된 이메일만 통과 → GrowthBook 노출.

> 이 게이트가 **회원가입 잠금 역할**도 겸한다: GrowthBook의 `/register` 엔드포인트는 앱 자체로는 열려 있으나(이 버전엔 비활성 env 없음), Access를 통과한 본인 외에는 애초에 앱에 도달할 수 없다. 최초 본인 계정 생성 후에는 사실상 단독 접근.

---

## 7. 헬스체크

로컬:
```bash
docker compose ps                      # 컨테이너 상태(up)
curl -fsS -o /dev/null -w "front %{http_code}\n" http://localhost:3000
curl -fsS    -w "api   %{http_code}\n"            http://localhost:3100/healthcheck || \
curl -fsS -o /dev/null -w "api %{http_code}\n"    http://localhost:3100
```
터널/Access 경유:
```bash
curl -I https://gb.example.com         # Access 미인증 시 302 -> Cloudflare 로그인 (정상)
```

---

## 8. 운영 메모

- `.env`, `cloudflared/*.json`(자격증명), `cert.pem` 은 **절대 커밋 금지** (`.gitignore` 반영됨)
- 텔레메트리: `DISABLE_TELEMETRY=true` 적용. 완전 차단은 egress 방화벽에서 `*.growthbook.io`/`gravatar.com` 차단 권장(`SECURITY_AUDIT.md` §6)
- 이미지가 `growthbook/growthbook:latest` → 재현성 필요 시 특정 태그로 핀 고정
- 중지: `docker compose down` (데이터는 `mongodata` 볼륨에 유지) / 볼륨까지 삭제: `docker compose down -v`

---

## 9. 현재 배포 상태 (2026-06-01 구성 완료)

| 항목 | 값 |
|---|---|
| front URL | `https://growthbook.betc.co.kr` → `127.0.0.1:3001` (host 3001 → 컨테이너 3000) |
| api URL | `https://growthbook-api.betc.co.kr` → `127.0.0.1:3100` |
| Cloudflare tunnel | name `abtest`(내부 라벨), id `3ab37a58-628a-4e5d-b11a-4cda3e87fba4` |
| Account ID | `7d2473c9e13ce77574ac39956e02e49e` |
| Access team 도메인 | `throbbing-star-0fc7.cloudflareaccess.com` |
| Access 앱(front) | id `b233b3cb-8f7b-4c7b-9370-e5582f3bac0a` (`growthbook.betc.co.kr`) — **이메일 게이트 적용** |
| Access 앱(api) | **없음 (의도적 제거)** — 아래 §10 참고 |
| Access 정책(front) | `allow-owner-email` → `seongwonyoung0311@gmail.com` 만 Allow (One-time PIN) |
| 검증 | front 미인증 접근 시 **302 → cloudflareaccess.com 로그인**; api 는 GrowthBook 자체 인증(JWT)+CORS 로 보호 |

> **이력**: 초기엔 `abtest.betc.co.kr`/`abtest-api`로 구성했으나, 포트 3000을 공유하는
> **ga4-ops 대시보드(`ga4.betc.co.kr`, "BSC scorecard")** 와의 혼선을 피하려고
> `growthbook.betc.co.kr` / `growthbook-api.betc.co.kr` 로 이전. `abtest*` DNS·Access 앱은 삭제함.
> `ga4.betc.co.kr`(ga4-ops-dashboard 터널 `1cfc5703…`, `infra/cloudflare-tunnel.yml`)는 **무관·무영향**.

---

## 10. ⚠️ Access는 front 에만 — API 호스트는 게이트하지 않음 (중요)

GrowthBook은 SPA(브라우저)에서 `API_HOST`(`growthbook-api.betc.co.kr`)로 직접 XHR 호출한다.
**front·api 두 서브도메인을 동시에 Cloudflare Access로 걸면**, 브라우저의 API 호출이
Access의 인터랙티브 로그인 리다이렉트(→ `cloudflareaccess.com`)에 막혀 **CORS/CSP "Failed to fetch"** 가 발생한다.

→ 그래서 **api 호스트의 Access 앱은 제거**했다. API는 다음으로 보호된다:
- **GrowthBook 자체 JWT 인증** — 토큰은 Access로 막힌 front 에 로그인해야만 발급됨
- **CORS 가 `APP_ORIGIN`(`growthbook.betc.co.kr`) 로 제한** (검증: preflight `access-control-allow-origin: https://growthbook.betc.co.kr`)
- Cloudflare Tunnel 로만 접근 가능

잔여 리스크: `/auth/register` 등 일부 무인증 엔드포인트가 api 호스트에 열려 있음. 단,
그렇게 만든 계정은 **게이트된 UI 에 못 들어오고 org 도 없어** admin 데이터에 접근 불가.
더 강하게 막으려면 Cloudflare Access **Service Token** + WAF 규칙으로 `/auth/register` 등을 차단하는 방법이 있음(선택).

### 터널 영속화 — launchd 에이전트 (적용됨)
터널은 **launchd User Agent**로 상시 실행된다 (로그인 시 자동 시작 + 죽으면 KeepAlive 자동 부활).
`cloudflared service install`(전역 `~/.cloudflared/config.yml` = obsidian 터널)을 쓰지 않고
**전용 plist**로 분리했다 — 기존 obsidian/ga4 터널과 충돌 없음.

- plist: `~/Library/LaunchAgents/com.growthbook.cloudflared.plist`
  - 실행: `/opt/homebrew/bin/cloudflared tunnel --no-autoupdate --config <repo>/cloudflared/config.yml run`
  - `RunAtLoad=true`, `KeepAlive=true`
  - 로그: `cloudflared/tunnel.log`

관리 명령:
```bash
launchctl load   ~/Library/LaunchAgents/com.growthbook.cloudflared.plist   # 시작/등록
launchctl unload ~/Library/LaunchAgents/com.growthbook.cloudflared.plist   # 중지/해제
launchctl list com.growthbook.cloudflared                                  # 상태(PID) 확인
tail -f cloudflared/tunnel.log                                             # 로그
```
> 재부팅 후 자동 시작되지만, **Docker Desktop 이 떠 있어야** 컨테이너(origin)가 살아있다.
> Docker Desktop 도 "로그인 시 자동 시작"으로 켜두면 전체가 자동 복구된다.

### Access 정책 변경 (이메일 추가 등)
재발급한 Access 토큰으로:
```bash
ACC=7d2473c9e13ce77574ac39956e02e49e
# front 앱 정책 목록
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACC/access/apps/cd3621fe-4a2e-40a4-9070-3f6b53ce3371/policies"
```
> Access 설정에 쓴 API 토큰은 작업 후 삭제함(`cloudflared/.cf_api_token`). 필요 시 재발급(§ 길 A 권한) 후 사용.
