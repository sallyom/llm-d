# Dashboard Import Examples

This document provides example commands and procedures for importing the llm-d monitoring dashboards.

## Grafana Dashboard Import

### Using Grafana UI

1. Log in to your Grafana instance
2. Navigate to **Dashboards** → **Import**
3. Click **Upload JSON file**
4. Select one of the dashboard files:
   - `grafana/dashboards/llm-d-dashboard.json` (basic monitoring)
   - `grafana/dashboards/llm-d-comprehensive-dashboard.json` (comprehensive monitoring with all Tier 1 and Tier 2 metrics)
5. Configure the dashboard:
   - **Name**: Use default or customize
   - **Folder**: Select target folder
   - **Prometheus datasource**: Select your Prometheus instance
6. Click **Import**

### Using Grafana API

```bash
# Set your Grafana URL and API key
GRAFANA_URL="http://localhost:3000"
GRAFANA_API_KEY="your-api-key-here"

# Import comprehensive dashboard
curl -X POST "$GRAFANA_URL/api/dashboards/db" \
  -H "Authorization: Bearer $GRAFANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d @grafana/dashboards/llm-d-comprehensive-dashboard.json

# Verify import
curl -H "Authorization: Bearer $GRAFANA_API_KEY" \
  "$GRAFANA_URL/api/search?query=llm-d%20Comprehensive"
```

### Using Grafana Provisioning

Create a provisioning file at `/etc/grafana/provisioning/dashboards/llm-d.yaml`:

```yaml
apiVersion: 1

providers:
  - name: 'llm-d-monitoring'
    orgId: 1
    folder: 'LLM Monitoring'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /etc/grafana/dashboards/llm-d
```

Copy dashboard files to the provisioning directory:

```bash
sudo mkdir -p /etc/grafana/dashboards/llm-d
sudo cp grafana/dashboards/*.json /etc/grafana/dashboards/llm-d/
sudo chown -R grafana:grafana /etc/grafana/dashboards/llm-d
sudo systemctl restart grafana-server
```

## Perses Dashboard Import

### Using Perses UI

1. Log in to your Perses instance
2. Navigate to **Dashboards**
3. Click **Create Dashboard** → **Import**
4. Click **Upload YAML** or paste the contents of `perses/llm-d-dashboard.yaml`
5. Review the dashboard configuration:
   - Verify datasource connection (Prometheus)
   - Check variable definitions
6. Click **Save**

### Using persesctl CLI

```bash
# Install persesctl if not already installed
# See: https://perses.dev/docs/user-guides/cli

# Set your Perses instance URL
PERSES_URL="http://localhost:8080"

# Import the dashboard
persesctl apply --file perses/llm-d-dashboard.yaml --url $PERSES_URL

# Verify the dashboard was created
persesctl get dashboard llm-d-basic-monitoring --url $PERSES_URL

# List all dashboards
persesctl get dashboards --url $PERSES_URL
```

### Using Perses API

```bash
# Set your Perses URL
PERSES_URL="http://localhost:8080"

# Import dashboard via API
curl -X POST "$PERSES_URL/api/v1/projects/default/dashboards" \
  -H "Content-Type: application/yaml" \
  --data-binary @perses/llm-d-dashboard.yaml

# Verify import
curl "$PERSES_URL/api/v1/projects/default/dashboards/llm-d-basic-monitoring"
```

## Post-Import Configuration

### Configure Datasource

After importing, ensure your Prometheus datasource is configured correctly:

**Grafana:**
1. Go to **Configuration** → **Data Sources**
2. Select your Prometheus datasource
3. Verify the URL points to your Prometheus instance
4. Click **Save & Test**

**Perses:**
1. Edit the dashboard YAML
2. Update the `spec.datasources.prometheus.plugin.spec.directUrl` field
3. Point it to your Prometheus instance URL

### Configure Variables

Both dashboards include template variables for filtering:

- **namespace**: Filter metrics by Kubernetes namespace
- **model_name**: Filter metrics by model name (Grafana comprehensive dashboard only)

These variables auto-populate from your Prometheus metrics. If you see "No options" in the dropdown:
1. Verify your Prometheus instance has metrics with `namespace` and `model_name` labels
2. Check that vLLM is running and exporting metrics
3. Ensure Prometheus is scraping the vLLM metrics endpoint

### Verify Dashboard Functionality

1. **Check Data Flow**:
   ```bash
   # Query Prometheus directly to verify metrics exist
   curl 'http://prometheus:9090/api/v1/query?query=vllm:generation_tokens_total'
   ```

2. **Select Namespace**: Use the namespace dropdown to filter to your deployment
3. **Check Panels**: Verify that panels show data or "No data" states
4. **Review Alerts**: If panels show "No data", check the troubleshooting section in README.md

## Example Import Session

Here's a complete example showing a successful import:

```bash
# 1. Clone or download the repository
git clone https://github.com/your-org/llm-d.git
cd llm-d/docs/monitoring

# 2. Verify dashboard files exist
ls -lh grafana/dashboards/
ls -lh perses/

# 3. Import to Grafana
export GRAFANA_URL="http://localhost:3000"
export GRAFANA_API_KEY="$(cat ~/.grafana-api-key)"

curl -X POST "$GRAFANA_URL/api/dashboards/db" \
  -H "Authorization: Bearer $GRAFANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d @grafana/dashboards/llm-d-comprehensive-dashboard.json | jq '.'

# Expected output:
# {
#   "id": 1,
#   "slug": "llm-d-comprehensive-monitoring",
#   "status": "success",
#   "uid": "llm-d-comprehensive",
#   "url": "/d/llm-d-comprehensive/llm-d-comprehensive-monitoring",
#   "version": 1
# }

# 4. Import to Perses
persesctl apply --file perses/llm-d-dashboard.yaml --url http://localhost:8080

# Expected output:
# Dashboard "llm-d-basic-monitoring" created successfully

# 5. Access dashboards
echo "Grafana: $GRAFANA_URL/d/llm-d-comprehensive/llm-d-comprehensive-monitoring"
echo "Perses: http://localhost:8080/projects/default/dashboards/llm-d-basic-monitoring"
```

## Troubleshooting

If import fails, check:

1. **JSON/YAML syntax**: Run validation scripts
   ```bash
   ./scripts/validate-dashboard.sh grafana/dashboards/llm-d-comprehensive-dashboard.json
   ./scripts/validate-dashboard.sh perses/llm-d-dashboard.yaml
   ```

2. **API connectivity**: Verify you can reach Grafana/Perses
   ```bash
   curl -I http://localhost:3000/api/health  # Grafana
   curl -I http://localhost:8080/api/health  # Perses
   ```

3. **Permissions**: Ensure your API key has dashboard creation permissions

4. **Version compatibility**:
   - Grafana dashboards require Grafana 11.x or later
   - Perses dashboards require Perses 0.x

See [README.md](./README.md#troubleshooting) for more troubleshooting guidance.
