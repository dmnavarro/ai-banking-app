# DG Bank — AI Banking Demo

A fictional banking web app that demonstrates **TrendAI Vision One AI Application Security** (AI Guard + AI Scanner) and **Vision One Code Security** alongside **Amazon Bedrock** (Claude) in a realistic customer-facing scenario.

Built for Sales Engineers to deploy in their own AWS account and use during customer demos.

---

## TrendAI product integrations

| Product | Capability showcased |
|---|---|
| **Vision One AI Application Security — AI Guard** | Real-time prompt scanning on every chatbot message. Guard On by default when a server API key is configured. Falls back to local pattern matching automatically if the API is unreachable. Toggle Guard On/Off from the chat header pill. |
| **Vision One AI Application Security — AI Scanner** | Automated red-team attack campaigns using TMAS `aiscan llm`. Generates attack prompts across configurable objectives (Sensitive Data Disclosure, System Prompt Leakage, Malicious Code Generation, Agent Tool Definition Leakage), streams results live via SSE, and exports a full report. Supports both Custom and OpenAI-compatible target endpoints. |
| **Vision One Code Security** | Static analysis of the application source code during CI/CD. The GitHub Actions pipeline runs a TMAS artifact scan on every push, surfacing vulnerabilities before the container image reaches ECS. |

---

## What's in the demo

| Feature | Description |
|---|---|
| **C-3PO, The Assistant** | AI chatbot powered by Amazon Bedrock (Claude 3 Haiku) |
| **AI Guard** | TrendAI Vision One prompt scanning — Guard On (live API with demo fallback) or Guard Off |
| **Malicious Prompts** | Pre-built attack presets (prompt injection, jailbreak, social engineering, PII exfil) to trigger AI Guard |
| **AI Scanner** | Automated attack campaign powered by TMAS `aiscan llm` — streams live results via SSE, exports a full report |
| **Banking UI** | Realistic dashboard with account balance, transactions, cards, and quick actions |

---

## Deploy (fresh account)

### Prerequisites

- AWS CLI configured (`aws configure`)
- Docker installed and running
- An ACM wildcard certificate in your region — optional, for HTTPS

### One-command deploy

```bash
./deploy-ecs.sh --github-org <your-github-username>
```

With HTTPS:

```bash
./deploy-ecs.sh \
  --github-org <your-github-username> \
  --certificate-arn arn:aws:acm:<region>:<account>:certificate/<id>
```

The script will:
1. Create the ECR repository
2. Build and push the Docker image (`linux/amd64`)
3. Deploy the CloudFormation stack (VPC, ECS on EC2, ALB, IAM, OIDC)
4. Wait for the service to be healthy
5. Print the app URL, DNS target, and GitHub Actions role ARN

### After deploy

The script prints two things to finish setup:

**1. DNS** — add a CNAME at your DNS provider pointing your custom domain to the ALB DNS name printed by the script.

**2. GitHub Actions secret** — go to your repo → Settings → Secrets and variables → Actions:
```
AWS_ROLE_ARN = <role ARN printed by script>
```

After that, every push to `main` automatically builds and deploys to ECS.

### Re-deploy / update

```bash
./deploy-ecs.sh --github-org <your-github-username> --skip-oidc [--certificate-arn <arn>]
```

Use `--skip-oidc` on re-runs to avoid conflicts with the existing GitHub OIDC provider.

### Script options

| Option | Default | Description |
|---|---|---|
| `--github-org` | *(required)* | Your GitHub username or org |
| `--github-repo` | `ai-banking-app` | Repository name |
| `--region` | `ap-southeast-1` | AWS region |
| `--instance-type` | `t3.small` | EC2 instance type |
| `--bedrock-region` | `ap-southeast-1` | Bedrock API region |
| `--bedrock-model` | `anthropic.claude-3-haiku-20240307-v1:0` | Bedrock model ID |
| `--certificate-arn` | *(empty)* | ACM cert ARN for HTTPS |
| `--skip-oidc` | *(off)* | Skip OIDC provider creation |
| `--stack-name` | `dgbank-ai-app-demo-ecs` | CloudFormation stack name |

---

## Using the app

### Banking Queries tab

The default tab. Type any banking question or use the preset chips:

- **Account balance** — ask C-3PO for your balance
- **Recent transactions** — get a transaction summary
- **Transfer money** — initiate a transfer
- **Interest rates**, **Investment options**, **Replace card**, **Credit status**, **Auto bill pay**

C-3PO responds using Amazon Bedrock (Claude). Responses are scoped to banking — it will not answer off-topic questions.

### AI Guard

The **Guard** pill in the chat header controls scanning:

| State | Behaviour |
|---|---|
| **Guard On** | Live TrendAI Vision One API scanning on every message. Falls back to local pattern matching automatically if the API is unreachable. |
| **Guard Off** | Messages go straight to Bedrock, no scanning. |

Click the pill to toggle between Guard On and Guard Off.

**Default behaviour on deployment:** Guard On is active automatically when `TMAS_API_KEY` is set on the server (injected from SSM). No manual configuration needed for standard deployments.

**Force Demo Mode:** check the *Force Demo Mode* checkbox in AI Application Security Configuration to bypass the live API entirely and use local pattern matching only — useful for offline presentations.

**Setup for custom API key:**
1. Click the gear icon → **AI Application Security Configuration**
2. Enter your TrendAI Vision One API key (or leave blank to use the server default)
3. Select your region (defaults to Singapore)
4. Optionally enter a Guard ID / App Name (shown in Vision One dashboard)
5. Click **Save & Enable**

### Malicious Prompts tab

Pre-built attack prompts to demonstrate AI Guard blocking:

| Preset | Attack type |
|---|---|
| Prompt Injection | Override system instructions |
| Jailbreak / DAN | Bypass AI safety guidelines |
| Social Engineering | Impersonate bank IT to extract data |
| Financial Fraud | Request money laundering assistance |
| PII Exfiltration | Extract customer personal data |
| Competitor Intel | Extract internal business data |

With **Guard On** active, these will be blocked before reaching Bedrock. With **Guard Off**, they reach the model (which may still refuse, but no Vision One event is generated).

### AI Scanner

Click the red **AI Scanner** button (top navigation) to run an automated attack campaign powered by **TMAS `aiscan llm`**. Floating teaser cards above the chat button also link directly to the scanner.

**Demo mode** — runs a built-in set of attack prompts directly against any endpoint using the `/api/scanner/run` endpoint. No additional credentials needed.

**Live mode** — uses TMAS to generate and evaluate attack prompts professionally, streaming real-time progress via Server-Sent Events (SSE). Requires `TMAS_API_KEY` to be set on the server (injected automatically from SSM on ECS deployments).

Workflow:
1. **Step 1 — Target** — enter the chat endpoint URL. Select endpoint format: **Custom** or **OpenAI-compatible**. Optionally provide an API key and model.
2. **Step 2 — Attack Objectives** — choose which attack categories to test. Defaults to Sensitive Data Disclosure.
3. **Step 3 — Run** — click **Launch Scan**. In Live mode, a terminal streams TMAS output in real time. When complete, a per-objective summary shows how many techniques were blocked vs. passed.
4. **Export** — download a full text report including the scan log.

---

## Architecture

```
Browser
  └── ALB (HTTPS port 443, HTTP → HTTPS redirect)
        └── ECS Service (EC2, t3.small)
              └── Node.js Express app
                    ├── Chat API        → Amazon Bedrock (Claude)
                    ├── AI Guard proxy  → TrendAI Vision One AI Application Security
                    └── AI Scanner API  → TMAS aiscan llm (SSE streaming)
```

**AWS resources created by `deploy-ecs.sh`:**

- VPC with 2 public subnets across AZs
- Internet Gateway + route tables
- Application Load Balancer (HTTP + HTTPS)
- ECS Cluster on EC2 with Auto Scaling Group
- ECS Task Role with Bedrock invoke permissions
- GitHub Actions IAM Role (OIDC) for CI/CD
- CloudWatch Log Group for container logs

---

## GitHub Actions secrets

| Secret | Required | Description |
|---|---|---|
| `AWS_ROLE_ARN` | Yes | IAM role ARN printed by `deploy-ecs.sh` |
| `TMAS_API_KEY` | No | TrendAI Vision One API key with **AI Application Security** scope — used in three ways: (1) enables the `tmas artifact scan` step in CI, (2) stored in AWS SSM and injected into ECS to power AI Scanner Live mode, and (3) used as the default API key for AI Guard live scanning (no manual key entry needed after deployment) |

> **Getting the Vision One API key:** in the Vision One console go to **Administration → API Keys** and create a key with the *AI Application Security* permission. This is a different key from standard Bedrock/AWS credentials. Set it as the `TMAS_API_KEY` GitHub Actions secret and the CI pipeline will push it to SSM automatically on the next run.

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
