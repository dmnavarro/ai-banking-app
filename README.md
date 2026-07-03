# DG Bank — AI Banking Demo

A fictional banking web app that demonstrates **Trend Micro Vision One AI Application Security** (AI Guard) and **Amazon Bedrock** (Claude) in a realistic customer-facing scenario.

Built for Sales Engineers to deploy in their own AWS account and use during customer demos.

---

## What's in the demo

| Feature | Description |
|---|---|
| **Blane, The Assistant** | AI chatbot powered by Amazon Bedrock (Claude 3 Haiku) |
| **AI Guard** | Vision One prompt scanning — Demo, Guard On, or Guard Off modes |
| **Malicious Prompts** | Pre-built attack presets (prompt injection, jailbreak, social engineering, PII exfil) to trigger AI Guard |
| **AI Scanner** | Automated attack campaign tool — runs attack prompts against any OpenAI-compatible endpoint |
| **Banking UI** | Realistic dashboard with account balance, transactions, cards, and quick actions |

---

## Deploy (fresh account)

### Prerequisites

- AWS CLI configured (`aws configure`)
- Docker installed and running
- An ACM wildcard certificate in your region (e.g. `*.hawkins.global`) — optional, for HTTPS

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

**1. DNS** — add a CNAME at your DNS provider:
```
bank.hawkins.global  →  <ALB DNS name printed by script>
```

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

- **Account balance** — ask Blane for your balance
- **Recent transactions** — get a transaction summary
- **Transfer money** — initiate a transfer
- **Interest rates**, **Investment options**, **Replace card**, **Credit status**, **Auto bill pay**

Blane responds using Amazon Bedrock (Claude). Responses are scoped to banking — it will not answer off-topic questions.

### AI Guard

The **Guard** pill in the chat header controls scanning mode:

| State | Behaviour |
|---|---|
| **Guard Off** | Messages go straight to Bedrock, no scanning |
| **Demo** | Pattern-matching locally — no API call needed, great for offline demos |
| **Guard On** | Live Vision One API scanning on every message |

Click the pill to cycle between states. Configure Vision One credentials in **Settings** (gear icon).

**Setup for live mode:**
1. Click the gear icon → AI Guard Configuration
2. Enter your Vision One API key and select your region
3. Optionally enter a Guard ID / App Name (shown in Vision One dashboard)
4. Click **Save & Enable**
5. Click the Guard pill to switch to **Guard On**

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

With **Guard On** or **Demo** mode active, these will be blocked before reaching Bedrock. With **Guard Off**, they reach the model (which may still refuse, but no Vision One event is generated).

### AI Scanner

Click the **AI Scanner** button (top navigation) to run an automated attack campaign:

1. **Configure Target** — set the endpoint URL, API key, and model
2. **Select Attacks** — choose attack categories and individual prompts
3. **Results** — see which prompts were blocked vs. passed, with a downloadable report

The scanner can target the local chatbot (`/api/aiguard/scan`) or any external OpenAI-compatible endpoint.

---

## Architecture

```
Browser
  └── ALB (HTTPS port 443, HTTP → HTTPS redirect)
        └── ECS Service (EC2, t3.small)
              └── Node.js container (port 3000)
                    ├── /api/chat          → Amazon Bedrock (Claude)
                    └── /api/aiguard/scan  → Vision One AI Application Security
```

**AWS resources created by `deploy-ecs.sh`:**

- VPC with 2 public subnets across AZs
- Internet Gateway + route tables
- Application Load Balancer (HTTP + HTTPS)
- ECS Cluster on EC2 with Auto Scaling Group
- ECS Task Role with Bedrock invoke permissions
- GitHub Actions IAM Role (OIDC) for CI/CD
- CloudWatch Log Group (`/ecs/dgbank-ai-app-demo`)

---

## GitHub Actions secrets

| Secret | Required | Description |
|---|---|---|
| `AWS_ROLE_ARN` | Yes | IAM role ARN printed by `deploy-ecs.sh` |
| `TMAS_API_KEY` | No | Trend Micro TMAS key — enables security scan step in CI |

---

## Local development

```bash
npm install
npm start
# → http://localhost:3000
```

Bedrock calls will fail locally unless you have AWS credentials configured with Bedrock access. The app falls back gracefully — the UI still loads and AI Guard demo mode works without any AWS credentials.
