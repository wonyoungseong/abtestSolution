# SECURITY_AUDIT.md — 외부 데이터 전송 보안 검토

- **대상 레포**: `abtestSolution` (GrowthBook fork)
- **브랜치**: `apikey-drafts`
- **검토일**: 2026-06-01
- **검토 범위**: `packages/` 전체 (제외: `localhost`/`127.0.0.1`/`test`/`spec`/`node_modules`/`dist`)
- **검토 방식**: `fetch`/`axios`/`http(s)`/하드코딩 `https://` 도메인 전수 grep + 텔레메트리·라이선스 키워드 스캔 + 업스트림 대비 `git diff`

---

## 0. 핵심 요약 (TL;DR)

| 구분 | 결론 |
|---|---|
| **자동 발신 텔레메트리** | 있음 — Jitsu → `https://t.growthbook.io`. **`DISABLE_TELEMETRY=true`로 차단** (본 배포에 적용 완료) |
| **자동 발신 (그 외)** | GrowthBook 자체 도그푸딩 feature fetch(`cdn.growthbook.io`), Gravatar 아바타(`gravatar.com`) — env 토글 없음, 코드/네트워크 차단 필요 |
| **라이선스 검증 phone-home** | **없음** — `enterprise/src/license.ts`는 완전 오프라인 서명 검증, 백엔드에서 import조차 안 함 |
| **조건부 발신** | Sentry / 웹훅 / SMTP / Stripe / Auth0 / 데이터소스 통합 — 모두 **사용자가 설정해야만** 발신 (기본 OFF) |
| **fork가 추가한 외부 호출** | **0건** — `apikey-drafts`의 변경분은 API Key/feature-draft 파일에 한정, 네트워크 호출 추가·변경 없음 |
| **⚠️ 런타임 주의** | `docker-compose.yml`은 로컬 소스가 아니라 `growthbook/growthbook:latest` **이미지**를 실행 → 실제 발신 동작은 최신 이미지 기준. `DISABLE_TELEMETRY=true`는 최신 이미지에서도 유효 |

---

## 1. 자동 발신 (설정 없이 무조건 나가는 호출) — 우선 차단 대상

### 1.1 익명 사용 통계 텔레메트리 (Jitsu)
- **파일**: `packages/front-end/services/track.ts:71`
- **목적지**: `https://t.growthbook.io` (Jitsu tracking host, key `js.y6nea.yo6e8isxplieotd6zxyeu5`)
- **트리거**: 프런트엔드 클라이언트 이벤트 — 예) `track("App Load")` (`pages/_app.tsx:56`), 폼 사용/이탈 등 UI 이벤트
- **보내는 데이터** (self-hosted 기준, `track.ts:40-60`):
  - 이벤트명, `page_url`/`doc_path`(경로만, host는 `"self-hosted"`로 마스킹)
  - `build_sha`, `build_date`, `configFile`(bool), `role`
  - `org_hash` = **md5(orgId)**, `user_id_hash` = **md5(userId)** — *해시*만 전송
  - `user_id`/`org` 원문은 **cloud에서만** 전송 (self-hosted는 빈 문자열)
  - `source_ip`/`referer`/`doc_search`는 의도적으로 공란
- **민감도**: 낮음~중간. PII 원문은 없으나 org/user의 md5 해시 + 빌드 버전 + 사용 패턴이 GrowthBook으로 전송됨
- **차단 방법**: **`DISABLE_TELEMETRY=true`** (또는 `=1`) 환경변수. `=debug`면 콘솔에만 출력하고 발신 안 함. (`env.ts:41 isTelemetryEnabled`, `init.ts:42-46`) → **본 배포 `docker-compose.yml`에 적용 완료**

### 1.2 GrowthBook 도그푸딩 feature fetch
- **파일**: `packages/front-end/pages/_app.tsx:61`
- **목적지**: `https://cdn.growthbook.io/api/features/key_prod_cb40dfcb0eb98e44`
- **트리거**: **모든 라우트 변경 시** 무조건 GET (`useEffect`, deps `router.pathname`)
- **보내는 데이터**: 요청 바디 없음(GET). 단 GrowthBook CDN에 **서버/브라우저의 outbound IP + 접속 사실**이 노출됨. 응답으로 GrowthBook UI 자체의 기능 플래그를 받아옴 (GrowthBook이 자기 제품을 자기 제품으로 운영)
- **민감도**: 낮음 (수신만, 발신 데이터 없음) — 단 "외부와 통신한다"는 자체가 폐쇄망 요건엔 부적합
- **차단 방법**: env 토글 **없음**. 택1
  - (a) egress 방화벽/네트워크 정책에서 `*.growthbook.io` 차단
  - (b) `_app.tsx:61`의 fetch 블록 제거 후 자체 빌드 (현재 배포는 prebuilt 이미지 사용이라 코드 패치는 빌드 전환 필요)
  - (c) **권장**: Cloudflare Access 게이트 + 아웃바운드 모니터링으로 운영상 통제

### 1.3 Gravatar 아바타
- **파일**: `packages/front-end/components/Avatar.tsx:11`
- **목적지**: `https://www.gravatar.com/avatar/{md5(email)}?d=identicon`
- **트리거**: 사용자 아바타 렌더링 시 브라우저가 GET
- **보내는 데이터**: **md5(이메일)** 이 Gravatar(Automattic)로 전송 → 이메일 열거/추적에 악용 가능
- **민감도**: 중간 (브라우저 발신, 서버 egress 아님)
- **차단 방법**: 브라우저 단이라 서버 차단 불가. 코드 패치(`d=identicon`는 이미 fallback이므로 URL 자체를 로컬 identicon 생성으로 교체)하거나, 클라이언트 네트워크 정책에서 gravatar 차단

---

## 2. 라이선스 검증 — phone-home 없음 (안전)

- **파일**: `packages/enterprise/src/license.ts`
- **동작**: `GB_LICENSE` / `LICENSE_PRIVATE_KEY` 환경변수의 라이선스 문자열을 **로컬에서 crypto 서명 검증**(`verify("sha256", ...)`)만 수행. 발급일/만료일/좌석수 디코딩도 전부 로컬 계산
- **네트워크 호출**: **없음**
- **추가 확인**: `packages/back-end/src`에서 `enterprise`/`license` import **0건** → 이 fork 버전(2022 base)에선 라이선스 서버 통신 경로 자체가 존재하지 않음
- 키워드 스캔(`license`)에서도 외부 라이선스 서버 URL 미발견

---

## 3. 조건부 발신 (사용자가 설정해야만 나감 — 기본 OFF)

| # | 호출 | 파일 | 목적지 | 보내는 데이터 | 활성 조건 / 차단 |
|---|---|---|---|---|---|
| 3.1 | Sentry 에러 리포팅 | `front-end/services/env.ts:28-31`, `init.ts:48` | Sentry DSN 호스트 | 프런트 에러 스택트레이스 | `NEXT_PUBLIC_SENTRY_DSN` **설정 시에만**. 기본 공란 → OFF. 차단: DSN 미설정 |
| 3.2 | 아웃바운드 웹훅 | `back-end/jobs/webhooks.ts:58` (`node-fetch`) | **사용자가 등록한** `webhook.endpoint` | feature/experiment 변경 페이로드(HMAC 서명 포함) | 웹훅을 직접 생성해야 발신. 차단: 웹훅 미등록 |
| 3.3 | SMTP 이메일 | `back-end/services/email.ts:31` (`nodemailer`) | 설정한 SMTP 서버 | 초대/비밀번호 재설정 메일 (`APP_ORIGIN` 링크 포함) | `EMAIL_*` env 설정 시. 차단: 미설정(초대 메일 기능만 비활성) |
| 3.4 | Stripe 결제 | `back-end/controllers/stripe.ts` | Stripe API | 구독/결제 (cloud billing) | `STRIPE_SECRET` 설정 시. self-hosted 기본 OFF |
| 3.5 | Auth0 로그인 | `front-end/authSources/auth0AuthSource.tsx:8`, `back-end/services/auth.ts:57` | `growthbook.auth0.com`, `api.growthbook.io` | OAuth 토큰 교환 | **`IS_CLOUD`일 때만**. self-hosted는 `localAuthSource` 사용(`services/auth.tsx:119`) → OFF |
| 3.6 | 데이터소스/통합 쿼리 | `back-end/integrations/*`, `controllers/datasources.ts:446` | Mixpanel(`mixpanel.com`), Google Analytics/Sheets(`googleapis.com`), BigQuery, Postgres 등 | **사용자 분석 데이터 쿼리** — 본인이 등록한 자격증명으로 본인 데이터 창고에 질의 | 데이터소스 등록 시. 제품 본질 기능(텔레메트리 아님). 자격증명은 `ENCRYPTION_KEY`로 AES 암호화 저장(`services/datasource.ts`) |
| 3.7 | SDK 라이브러리 기본 호스트 | `packages/sdk-js/src/GrowthBook.ts:197-198` | `rt.growthbook.io`(스트리밍) 등 | 최종 사용자에게 배포되는 **클라이언트 SDK**의 기본값 | self-hosting 시 SDK가 **본인 API 호스트**를 바라보게 설정. 서버 자체 egress 아님 |

> 3.6은 GrowthBook의 존재 이유(실험 결과 분석)이며 "외부 유출"이 아니라 **사용자→사용자 데이터 창고** 통신이다. 다만 자격증명이 평문이 아니라 `ENCRYPTION_KEY` 기반 AES로 저장되는지 확인됨(`services/datasource.ts:19-23`) — 따라서 `ENCRYPTION_KEY`를 강한 값으로 두는 것이 중요(본 배포 적용).

---

## 4. fork(`apikey-drafts`)가 추가/변경한 외부 호출 — git 검증

- **업스트림 분기점(merge-base)**: `c8dc3986a`
- **fork 고유 변경**: 기능 커밋 1개 `1beca5618` ("Option to include unpublished feature changes in dev API endpoint", 작성자 Jeremy Dorn) + 머지 커밋
- **변경된 파일 전체** (`git diff --name-only c8dc3986a..apikey-drafts`):
  ```
  CONTRIBUTING.md
  packages/back-end/src/app.ts
  packages/back-end/src/controllers/features.ts
  packages/back-end/src/controllers/organizations.ts
  packages/back-end/src/models/ApiKeyModel.ts
  packages/back-end/src/services/apiKey.ts
  packages/back-end/src/services/features.ts
  packages/back-end/types/apikey.d.ts
  packages/docs/pages/app/api.mdx
  packages/front-end/components/Settings/ApiKeys.tsx
  packages/front-end/components/Settings/ApiKeysModal.tsx
  ```
- **결론**: 변경 파일은 **전부 API Key 발급/feature-draft 노출** 관련. `track.ts`/`_app.tsx`/`webhooks.ts`/`Avatar.tsx`/`enterprise` 등 egress 파일은 **하나도 건드리지 않음**.
- **→ 이 fork는 원본 GrowthBook 대비 외부 전송 호출을 추가·변경하지 않았다.**
- ⚠️ 보안 측면 별도 주의(외부 호출과 무관): fork 커밋은 "**미published(draft) feature 변경을 dev API로 노출**"하는 옵션을 추가한다. 외부 노출 환경에서는 이 dev 엔드포인트가 인증 없이 draft를 흘리지 않는지(별도 API Key 필요 여부) 확인 권장. → API Key 인증 기반(`services/apiKey.ts`)이므로 키 유출 관리가 핵심.

---

## 5. 도메인 인벤토리 (grep 집계)

자동/조건부와 무관하게 코드에 등장하는 외부 도메인 (빈도 내림차순, 문서/링크 포함):

| 도메인 | 성격 |
|---|---|
| `docs.growthbook.io`, `www.growthbook.io`, `growthbook.io`, `app.growthbook.io` | UI 내 문서/마케팅 **링크** (자동 발신 아님) |
| `t.growthbook.io` | **텔레메트리** (§1.1) — `DISABLE_TELEMETRY`로 차단 |
| `cdn.growthbook.io` | 도그푸딩 feature fetch(§1.2) + 시드 예제 이미지(`controllers/admin.ts`) |
| `api.growthbook.io`, `rt.growthbook.io` | SDK 기본 호스트 / Auth0 audience (§3.5, §3.7) |
| `growthbook.auth0.com` | Auth0 (cloud 전용, §3.5) |
| `gravatar.com` | 아바타 (§1.3) |
| `fonts.googleapis.com`, `fonts.gstatic.com` | 웹폰트 (주로 `docs` 패키지) |
| `googleapis.com` | Google Analytics/Sheets 데이터소스 (§3.6) |
| `mixpanel.com` | Mixpanel 데이터소스 (§3.6) |
| `github.com`, `npmjs.com`, `jsdelivr.net`, `unpkg.com`, `youtu.be`, `chrome.google.com`, `exp-platform.com`, `stackimgur` 등 | UI 내 정적 **링크/문서 참조** (자동 발신 아님). `unpkg.com`은 비주얼 디자이너 스크립트(`templates/javascript.js`)로, 해당 기능 사용 시에만 |

---

## 6. 차단 조치 요약 (본 배포 적용 + 권장)

**즉시 적용 (이 배포에 반영)**
1. ✅ `DISABLE_TELEMETRY=true` — Jitsu 텔레메트리(§1.1) 차단
2. ✅ `ENCRYPTION_KEY` / `JWT_SECRET` 강한 랜덤값 — 데이터소스 자격증명 암호화·세션 보호
3. ✅ Sentry DSN 미설정 유지 (§3.1 OFF)
4. ✅ `IS_CLOUD` 미설정 → Auth0/Stripe 경로 비활성 (§3.4, §3.5)
5. ✅ Cloudflare Access 이메일 게이트 — 외부 노출 시 접근 통제 + §1.2/§1.3 도그푸딩·아바타도 인증된 내 브라우저에서만 발생

**폐쇄망/완전 차단이 필요하면 (추가 권장)**
6. egress 방화벽에서 `*.growthbook.io`, `gravatar.com` 아웃바운드 차단 → §1.2 도그푸딩 fetch까지 완전 봉쇄
7. 자체 빌드로 전환 시 `_app.tsx:61` fetch 블록과 `Avatar.tsx` gravatar URL 제거
8. 아웃바운드 트래픽 모니터링(컨테이너 네트워크 로그)으로 예상 외 발신 감시

**운영 주의**
9. `docker-compose.yml`이 `growthbook/growthbook:latest` 이미지를 쓰므로, 본 소스 코드 감사 결과와 실제 런타임은 다를 수 있음. 재현성·감사가능성이 필요하면 특정 태그 핀 고정 또는 로컬 소스 자체 빌드 권장.
