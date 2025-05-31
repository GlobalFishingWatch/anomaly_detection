# 🚀 Anomaly Detection Quickstart

This guide will get you running anomaly detection on public BigQuery data in ~30 minutes.

## Prerequisites

- GCP account with billing enabled
- `gcloud` CLI installed and configured
- Docker installed locally

## 🎯 What You'll Build

A working anomaly detection system that:
- Monitors NYC Citibike daily trip counts
- Detects unusual spikes or drops in bike usage  
- Uses public BigQuery data (no private data required)
- Runs entirely in your own GCP project

## 📋 Step 1: Create GCP Project

```bash
# Create new project (replace with your preferred ID)
export PROJECT_ID="anomaly-detection-demo-$(date +%s)"
gcloud projects create $PROJECT_ID --name="Anomaly Detection Demo"

# Set as active project
gcloud config set project $PROJECT_ID

# Enable billing (you'll need to do this in Console if not already linked)
echo "⚠️  Enable billing for project $PROJECT_ID in GCP Console"
echo "💡 Don't worry - this demo uses mostly free tier resources!"
```

## 🔧 Step 2: Enable APIs & Create Service Account

```bash
# Enable required APIs
gcloud services enable \
  bigquery.googleapis.com \
  cloudbuild.googleapis.com \
  cloudrun.googleapis.com \
  cloudscheduler.googleapis.com

# Create service account
gcloud iam service-accounts create anomaly-detection \
  --description="Anomaly Detection Service Account" \
  --display-name="Anomaly Detection"

# Grant permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

## 📊 Step 3: Create BigQuery Dataset

```bash
# Create dataset
bq mk --location=US --dataset $PROJECT_ID:anomaly_detection_demo

echo "✅ Dataset created: $PROJECT_ID.anomaly_detection_demo"
```

## ⚙️ Step 4: Configure Environment

```bash
# Set environment variables
export GCP_PROJECT_ID=$PROJECT_ID
export BQ_DATASET="anomaly_detection_demo"
export DBT_ENVIRONMENT="demo"

# Save to shell profile for persistence
echo "export GCP_PROJECT_ID=$PROJECT_ID" >> ~/.bashrc
echo "export BQ_DATASET=anomaly_detection_demo" >> ~/.bashrc  
echo "export DBT_ENVIRONMENT=demo" >> ~/.bashrc
```

## 🏃‍♂️ Step 5: Run the Demo

```bash
# Clone and navigate to repo (if not already done)
git clone <your-repo-url>
cd anomaly_detection

# Switch to our refactoring branch
git checkout refactor/multi-project-support

# Run the quickstart demo
cd quickstart
docker-compose up --build

# This will:
# 1. Generate forecasts for NYC Citibike data
# 2. Detect anomalies using MSTL algorithm  
# 3. Store results in your BigQuery dataset
# 4. Print detected anomalies to console
```

## 🎉 Step 6: View Results

```bash
# Query results in BigQuery
bq query --use_legacy_sql=false "
SELECT 
  timestamp,
  actual_value,
  forecast_value,
  anomaly_type,
  delta_rel
FROM \`$PROJECT_ID.anomaly_detection_demo.demo_results\`
WHERE anomaly_type != 'normal'
ORDER BY timestamp DESC
LIMIT 10
"
```

## 🧹 Cleanup (Optional)

```bash
# Delete the entire project to avoid any charges
gcloud projects delete $PROJECT_ID
```

## 📈 Next Steps

Once the demo works:

1. **Explore Results**: Check BigQuery tables for forecast vs actual data
2. **Modify Config**: Edit `quickstart/config_demo.yaml` to try different algorithms
3. **Add Your Data**: Replace demo data with your own time series
4. **Set Up Alerting**: Configure Slack notifications for real anomalies
5. **Deploy Production**: Follow `PROJECT_SETUP.md` for full infrastructure

## 💡 Demo Data Details

**Dataset**: NYC Citibike trip counts  
**Source**: `bigquery-public-data.new_york_citibike.citibike_trips`  
**Time Range**: Last 2 years of daily aggregated data  
**Algorithms**: MSTL (seasonal), Mean (baseline)  
**Expected Anomalies**: Weather events, holidays, system outages

## 🔍 Troubleshooting

**Problem**: Permission denied accessing BigQuery  
**Solution**: Ensure billing is enabled and service account has correct roles

**Problem**: Docker build fails  
**Solution**: Ensure Docker is running and you have internet access

**Problem**: No anomalies detected  
**Solution**: This is normal! Real anomalies are rare. Check forecast accuracy instead.

## 📞 Need Help?

- Check logs: `docker-compose logs`
- Verify setup: `gcloud projects describe $PROJECT_ID`
- Test BigQuery: `bq ls $PROJECT_ID:anomaly_detection_demo`