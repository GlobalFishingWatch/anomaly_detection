# New Project Setup Template

This template shows how to set up anomaly detection for a new GCP project.

## Steps to Create a New Project Configuration

### 1. Create Project Directory
```bash
mkdir -p configs/your-project-id/{dbt_seeds,dataloader}
```

### 2. Copy Template Files
```bash
# Copy from demo project as starting point
cp configs/anomaly-detection-demo-461518/dbt_seeds/* configs/your-project-id/dbt_seeds/
cp configs/anomaly-detection-demo-461518/dataloader/* configs/your-project-id/dataloader/
cp configs/anomaly-detection-demo-461518/terraform.tfvars configs/your-project-id/
```

### 3. Customize Configuration
1. **terraform.tfvars**: Update project ID, service account, docker registry
2. **dataloader/config_demo.yaml**: 
   - Update source datasets to your data
   - Modify SQL queries for your tables
   - Adjust algorithm parameters
3. **dbt_seeds/config_descriptions_dev.csv**: Update descriptions for your configs
4. **dbt_seeds/thresholds_dev.csv**: Set appropriate thresholds for your data

### 4. Set Up Authentication
```bash
gcloud config configurations create your-project-config
gcloud config configurations activate your-project-config
gcloud config set account your-email@domain.com
gcloud config set project your-project-id
gcloud auth application-default login
```

### 5. Bootstrap Infrastructure
```bash
# Update bootstrap terraform.tfvars with your project
cd terraform/bootstrap
# Edit terraform.tfvars with your project_id
terraform init
terraform apply
```

### 6. Deploy and Test
```bash
export ANOMALY_PROJECT=your-project-id
# Follow deployment instructions
```

## Project Structure
```
configs/your-project-id/
├── dbt_seeds/
│   ├── config_descriptions_dev.csv
│   └── thresholds_dev.csv
├── dataloader/
│   └── config_demo.yaml  # Rename to config_dev.yaml
└── terraform.tfvars
```