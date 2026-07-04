# DG Bank — AI Banking Demo

A fictional banking web app that demonstrates **TrendAI Vision One AI Application Security** (AI Guard + AI Scanner) and **Vision One Code Security** alongside **Amazon Bedrock** (Claude) in a realistic customer-facing scenario.

Built for Sales Engineers to deploy in their own AWS account and use during customer demos.

---

## Table of contents

- [TrendAI product integrations](#trendai-product-integrations)
- [What's in the demo](#whats-in-the-demo)
- [Resources deployed](#resources-deployed)
- [Prerequisites](#prerequisites)
- [Full deployment walkthrough](#full-deployment-walkthrough)
- [Using the app](#using-the-app)
  - [AI Guard](#ai-guard)
  - [AI Scanner](#ai-scanner)
  - [File Security](#file-security)
  - [Code Security](#code-security)
- [Script reference](#script-reference)
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
| **Vision One Network Security — Cloud IPS** | Deployed inline on the VPC via AWS Network Firewall with AWS managed threat signature rule groups (malware, exploits, IOCs). Inspects all traffic to and from the ECS workload and blocks known exploit attempts, vulnerability scans, and malicious traffic at the network layer — complementing AI Guard which protects at the AI prompt layer. |

---

## What's in the demo

| Feature | Description |
|---|---|
| **C-3PO, The Assistant** | AI chatbot powered by Amazon Bedrock (Claude 3 Haiku) |
| **AI Guard** | TrendAI Vision One prompt scanning — Guard On (live API with demo fallback) or Guard Off |
| **Malicious Prompts** | Pre-built attack presets (prompt injection, jailbreak, social engineering, PII exfil) to trigger AI Guard |
| **AI Scanner** | Automated attack campaign powered by TMAS `aiscan llm` — streams live results via SSE, exports a full report |
| **File Security** | Pay Bills upload flow with Storage mode (S3 + Vision One Lambda) and SDK mode (inline scan before storage) |
| **Code Security** | TMAS artifact scan runs in GitHub Actions on every push — findings visible in the CI workflow log |
| **Banking UI** | Realistic dashboard with randomised account balance, transactions, cards, and quick actions |

---

## Resources deployed

### `deploy-ecs.sh` — main infrastructure (CloudFormation: `cloudformation/ecs.yml`)

**Networking**
- VPC (10.0.0.0/16) with 2 public subnets and 2 firewall subnets across AZs
- Internet Gateway + per-AZ route tables + IGW ingress route table
- AWS Network Firewall with TrendAI Cloud IPS managed rule groups

**Compute**
- ECS Cluster (EC2 launch type, t3.small by default)
- ECS Auto Scaling Group + Launch Template (Amazon ECS-optimized AMI)
- ECS Task Definition + Service
- Application Load Balancer with HTTP (and optional HTTPS) listener

**IAM**
- ECS Task Role — Bedrock invoke, S3 read/write, SSM read
- EC2 Instance Role — ECS agent, ECR pull, SSM managed instance
- GitHub Actions IAM Role + OIDC Provider for passwordless CI/CD

**Other**
- ECR Repository (created before the CF stack)
- CloudWatch Log Group for container logs
- SSM Parameter for TMAS API key (written by CI on first push, read by ECS at runtime)

### `deploy-filesecurity.sh` — File Security buckets (CloudFormation: `cloudformation/filesecurity-buckets.yaml`)

- S3 Scanning Bucket — files uploaded here are scanned by the Vision One Lambda
- S3 Quarantine Bucket — clean vs. quarantined results tracked via S3 object tags
- IAM Managed Policy for S3 access, attached to the ECS task role

---

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS CLI | Configured with an IAM identity that has broad CloudFormation/EC2/ECS/IAM permissions |
| Docker | Must be running; used to build the `linux/amd64` container image |
| GitHub account | You must fork this repo so you control the Actions workflow |
| Vision One API key | Go to **Administration → API Keys** and create a key with **AI Application Security** scope. This single key powers AI Guard live mode, AI Scanner live mode, and File Security SDK mode. |
| Amazon Bedrock model access | In the AWS console → Bedrock → Model access, enable **Claude 3 Haiku** (or your chosen model) in your target region |
| (Optional) ACM certificate | For HTTPS — request a wildcard cert in ACM before running the deploy script |

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
| File Security Storage | Pay Bills → Storage mode → upload a file → scan result appears |
| File Security SDK | Pay Bills → SDK mode → upload a file → instant inline result |
| Code Security | GitHub Actions → latest run → expand **Code Security Scan (TMAS)** step |
| Network Firewall | Vision One console → Network Security → Cloud IPS events |

---

## Using the app

### AI Guard

**What it does:** Scans every chatbot message in real time through TrendAI Vision One AI Application Security before it reaches Bedrock. Malicious prompts are blocked instantly — the model never sees them.

**How to demo:**
1. The **Guard** pill in the chat header shows the current state. Click it to toggle Guard On / Guard Off.
2. Switch to the **Malicious Prompts** tab and fire any of the preset attack chips:

| Preset | Attack type |
|---|---|
| Prompt Injection | Override system instructions |
| DAN Jailbreak | Bypass AI safety guidelines |
| Social Engineering | Impersonate bank IT to extract data |
| Financial Crime | Request money laundering assistance |
| PII Exfiltration | Extract customer personal data |
| Competitor Intel | Extract internal business data |

With **Guard On**, blocked messages never reach Bedrock — a *Blocked by AI Guard* card appears in the chat. With **Guard Off**, the prompt reaches the model (which may still refuse, but no Vision One event is generated).

**Configuration:**
- **Default on deployment:** Guard On activates automatically when `TMAS_API_KEY` is set on the server. No manual setup needed.
- **Force Demo Mode:** Tick the *Force Demo Mode* checkbox in the gear menu to use local pattern matching only — useful for offline presentations.
- **Custom API key:** Gear icon → AI Application Security Configuration → enter your key, select your region, click **Save & Enable**.

---

### AI Scanner

**What it does:** Runs an automated red-team attack campaign against any AI endpoint using **TMAS `aiscan llm`**. Tests multiple attack objectives and shows which techniques were blocked vs. which got through.

**How to demo:**
1. Click the **AI Scanner** button in the top navigation (or the floating teaser card above the chat button).
2. **Step 1 — Target:** Enter the chat endpoint URL. Choose endpoint format: **Custom** (our chatbot format) or **OpenAI-compatible**. Optionally provide an API key and target model ID.
3. **Step 2 — Attack Objectives:** Select which attack categories to run (Sensitive Data Disclosure, System Prompt Leakage, Malicious Code Generation, Agent Tool Definition Leakage).
4. **Step 3 — Launch:** Click **Launch Scan**.
   - **Demo mode** — runs built-in attack prompts locally. No TMAS credentials required.
   - **Live mode** — invokes TMAS `aiscan llm` on the server, streaming real-time output via SSE. Requires `TMAS_API_KEY`.
5. When complete, a per-objective scorecard shows blocked vs. passed techniques. Click **Export** to download the full scan log.

> Live mode activates automatically when `TMAS_API_KEY` is configured on the server — no manual key entry needed after deployment.

---

### File Security

**What it does:** Scans file uploads in the **Pay Bills** feature using Vision One File Security. Two modes demonstrate different integration approaches.

**How to demo:**
1. From the dashboard, click **Pay Bills** in the quick actions.
2. Choose a mode using the toggle at the top:

**Storage mode** (Vision One File Security — Storage integration)
- Drop or select a file (PDF, image, or TXT, up to 10 MB).
- The file is uploaded directly to an S3 scanning bucket via a presigned URL.
- Vision One File Security's Lambda monitors the bucket and scans the file automatically.
- The app polls the S3 object tags (`fss-scanned`, `fss-scan-result`) and shows the result when ready.
- Clean files show a green *File cleared — Submit Payment* card. Threats show a red *File quarantined* card.

**SDK mode** (Vision One File Security — SDK integration)
- Drop or select a file.
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

## Script reference

### `deploy-ecs.sh`

| Option | Default | Description |
|---|---|---|
| `--github-org` | *(required)* | Your GitHub username or org |
| `--github-repo` | `ai-banking-app` | Repository name |
| `--region` | `ap-southeast-1` | AWS region |
| `--instance-type` | `t3.small` | EC2 instance type |
| `--bedrock-region` | `ap-southeast-1` | Bedrock API region |
| `--bedrock-model` | `anthropic.claude-3-haiku-20240307-v1:0` | Bedrock model ID |
| `--certificate-arn` | *(empty)* | ACM cert ARN for HTTPS |
| `--skip-oidc` | *(off)* | Skip OIDC provider creation on re-runs |
| `--stack-name` | `dgbank-ai-app-demo-ecs` | CloudFormation stack name |

### `deploy-filesecurity.sh`

| Option | Default | Description |
|---|---|---|
| `--region` | `ap-southeast-1` | AWS region |
| `--ecs-stack` | `dgbank-ai-app-demo-ecs` | Name of the ECS CF stack (to find the task role) |

---

## Local development

```bash
npm install
npm start
# → http://localhost:3000
```

Bedrock calls will fail locally unless you have AWS credentials configured with Bedrock access. The app falls back gracefully — the UI still loads and AI Guard falls back to demo pattern matching without any credentials.

To test AI Guard locally with a real key, set `TMAS_API_KEY` in your environment before starting:

```bash
TMAS_API_KEY=<your-key> npm start
```
