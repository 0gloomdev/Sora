# Spec: Gitea Actions Pipeline for Module Validation

**Status:** [Ready for Dev]

## 1. PROBLEM STATEMENT

Sora's modular architecture relies on external JavaScript scraping modules that are pushed to a private Gitea repository. Currently, there's no automated validation when modules are pushed. Modules with syntax errors, timeout issues, or broken selectors can break the app at runtime. We need an automated validation pipeline that runs on every push to the modules repository.

## 2. PIPELINE ARCHITECTURE

### Trigger
- **Event**: `push` to any branch on the modules repository
- **Paths**: Only trigger on `*.js` file changes (module scripts)
- **Branches**: All branches (feature, hotfix, main)

### Pipeline Stages

```
push → validate → test → review → deploy
```

### Stage Details

#### Stage 1: Validate (Static Analysis)
- **Runner**: `ubuntu-latest` (self-hosted lightweight runner)
- **Timeout**: 5 minutes
- **Steps**:
  1. Checkout module repository
  2. Install Node.js 20 (for linting)
  3. Run ESLint with Sora's custom rules
  4. Validate JS syntax with `node --check`
  5. Check for forbidden patterns (eval, Function constructor, etc.)

#### Stage 2: Test (Runtime Validation)
- **Runner**: `ubuntu-latest` (self-hosted with Sora runtime)
- **Timeout**: 15 minutes
- **Steps**:
  1. Start Sora runtime in headless mode
  2. Load module in isolated context
  3. Execute `searchResults`, `extractDetails`, `extractEpisodes`, `extractStreamUrl` with mock data
  4. Validate output schema matches expected types
  5. Measure execution time (fail if > 30s per function)

#### Stage 3: Review (Manual Gate)
- **Trigger**: Manual approval required
- **Condition**: Only if Stage 1 & 2 pass
- **Action**: Update `modules/index.json` with `status: "manual_review"`
- **Notification**: Webhook to Discord/Slack with test results

#### Stage 4: Deploy (Auto-merge)
- **Trigger**: Manual approval on PR
- **Action**: Merge to `main`, tag release
- **Post-deploy**: Invalidate ModuleCacheManager cache for updated modules

## 3. GITEA ACTIONS WORKFLOW (YAML)

```yaml
name: "Module Validation Pipeline"

on:
  push:
    branches: ["**"]
    paths:
      - "**.js"
      - "!.github/**"
      - "!docs/**"
      - "!README.md"

permissions:
  contents: read
  pull-requests: write
  issues: write
  contents: write

env:
  NODE_VERSION: "20"
  GITEA_SERVER: "https://git.gloom-dev.local"
  SORA_RUNTIME_IMAGE: "sora/runtime:latest"

jobs:
  validate:
    name: "Static Validation"
    runs-on: ["self-hosted", "linux", "amd64"]
    timeout-minutes: 5
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: ${{ env.NODE_VERSION }}
          cache: npm

      - name: Install dependencies
        run: |
          npm ci --prefer-offline --no-audit --no-fund 2>/dev/null || npm install --prefer-offline --no-audit --no-fund

      - name: Lint with ESLint
        run: |
          npx eslint . --ext .js --max-warnings=0 --format compact

      - name: Syntax Check
        run: |
          for f in $(find . -name "*.js" -not -path "./node_modules/*" -not -path "./.git/*"); do
            node --check "$f" || exit 1
          done

      - name: Security Patterns
        run: |
          if grep -r "eval\|Function(" --include="*.js" . | grep -v node_modules; then
            echo "ERROR: Forbidden patterns found (eval, Function constructor)"
            exit 1
          fi

  test:
    name: "Runtime Validation"
    needs: validate
    runs-on: ["self-hosted", "linux", "amd64", "sora-runtime"]
    timeout-minutes: 15
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - name: Pull Sora Runtime
        run: |
          docker pull ${{ env.SORA_RUNTIME_IMAGE }} || true

      - name: Run Module Tests
        id: test
        run: |
          docker run --rm --network host \
            -v "${{ github.workspace }}:/workspace" \
            -w /workspace \
            ${{ env.SORA_RUNTIME_IMAGE }} \
            node --experimental-vm-modules ./test-module.js

      - name: Upload Test Results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: test-results.xml
          retention-days: 7

  review:
    name: "Manual Review Gate"
    needs: [validate, test]
    runs-on: ubuntu-latest
    timeout-minutes: 1440  # 24 hours
    steps:
      - name: Create Review PR
        if: github.event_name == 'push'
        uses: peter-evans/create-pull-request@v6
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          branch: review/${{ github.sha }}
          base: main
          title: "[Review] Module Update - ${{ github.ref_name }}"
          body: |
            ## Module Validation Results
            
            **Static Analysis**: ✅ Passed
            **Runtime Tests**: ✅ Passed
            
            **Module**: ${{ github.repository }}
            **Commit**: ${{ github.sha }}
            **Branch**: ${{ github.ref_name }}
            
            **Test Results**: See artifacts
            
            **Action Required**: Review and approve to merge.
          labels: |
            review-needed
            module-update
          draft: false

      - name: Update Module Index
        if: github.event_name == 'push'
        run: |
          jq --arg status "manual_review" \
             --arg commit "${{ github.sha }}" \
             --arg branch "${{ github.ref_name }}" \
             '.modules[] |= if .name == env.MODULE_NAME then . + {status: $status, last_commit: $commit, last_reviewed: now} else . end' \
             modules/index.json > modules/index.json.tmp && mv modules/index.json.tmp modules/index.json
          git config user.name "github-actions"
          git config user.email "actions@github.com"
          git commit -am "chore: flag module for review [skip ci]"
          git push

  deploy:
    name: "Deploy to Production"
    needs: review
    if: github.event_name == 'pull_request' && github.event.pull_request.merged == true
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Tag Release
        run: |
          VERSION=$(jq -r '.version' module.json)
          git tag -a "v${VERSION}" -m "Release v${VERSION}"
          git push origin "v${VERSION}"

      - name: Invalidate Cache
        run: |
          curl -X POST "${{ secrets.SORA_API_URL }}/api/cache/invalidate" \
            -H "Authorization: Bearer ${{ secrets.SORA_API_TOKEN }}" \
            -H "Content-Type: application/json" \
            -d '{"module": "${{ github.event.repository.name }}"}'

      - name: Notify
        run: |
          curl -X POST "${{ secrets.DISCORD_WEBHOOK }}" \
            -H "Content-Type: application/json" \
            -d '{"content": "✅ Module deployed: ${{ github.repository }} v${VERSION}"}'

# Concurrency control
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

## 5. RUNNER REQUIREMENTS

### Self-Hosted Runner Specs
| Component | Specification |
|-----------|--------------|
| OS | Ubuntu 22.04 LTS |
| CPU | 4 vCPU |
| RAM | 8 GB |
| Disk | 50 GB SSD |
| Docker | 24.0+ |
| Node.js | 20 LTS |
| Sora Runtime | Custom Docker image (`sora/runtime:latest`) |

### Runner Labels
- `self-hosted`
- `linux`
- `amd64`
- `sora-runtime` (for test stage)

### Runner Registration
```bash
# On runner machine
./config.sh --url https://git.gloom-dev.local --token ${RUNNER_TOKEN} \
  --labels self-hosted,linux,amd64,sora-runtime \
  --name gloom-runner-01
```

## 5. ACCEPTANCE CRITERIA

| Test Case | Expected Result |
|-----------|-----------------|
| `testStaticAnalysisPasses` | ESLint + syntax check pass on valid module |
| `testSyntaxErrorCaught` | Pipeline fails on syntax error |
| `testEvalCaught` | Pipeline fails on `eval()` usage |
| `testRuntimeTestsPass` | All 4 Sora functions execute within 30s each |
| `testTimeoutFails` | Function > 30s fails pipeline |
| `testEtag304NoDownload` | 304 response skips download |
| `testManualReviewGate` | PR created with `manual_review` label |
| `testCacheInvalidationOnDeploy` | Cache invalidated on merge |

## 6. DEPLOYMENT

### Secrets Required
| Secret | Description |
|--------|-------------|
| `SORA_API_TOKEN` | Bearer token for Sora API |
| `SORA_API_URL` | Sora backend URL |
| `DISCORD_WEBHOOK` | Notification webhook |
| `GITHUB_TOKEN` | Auto-provided |
| `RUNNER_TOKEN` | Runner registration token |

### Runner Registration
```bash
docker run -d --name gitea-runner \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  gitea/act_runner:latest \
  --url https://git.gloom-dev.local \
  --token ${RUNNER_TOKEN} \
  --labels self-hosted,linux,amd64,sora-runtime \
  --name gloom-runner-01
```

---

*Spec approved for implementation. Coder may proceed.*