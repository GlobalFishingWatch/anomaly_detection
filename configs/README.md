# Multi-Project Configuration Directory

This directory contains project-specific configurations for the anomaly detection system.

## Available Projects

### `world-fishing-827/` - Global Fishing Watch Production
- **Purpose**: Production maritime anomaly detection for GFW
- **Data**: Internal GFW datasets (fishing effort, AIS data, etc.)
- **Environments**: dev, staging, prod
- **Maintained by**: Global Fishing Watch team

### `anomaly-detection-demo-461518/` - Demo Project  
- **Purpose**: Demonstration using public data
- **Data**: Wikipedia pageviews (public BigQuery dataset)
- **User**: christianhomberg@gmail.com
- **Use case**: Testing and demonstration

### `template/` - New Project Template
- **Purpose**: Template and instructions for new organizations
- **Contains**: Setup guide and example configurations

## Usage

### Switch Between Projects
```bash
# Set environment variable to target specific project
export ANOMALY_PROJECT=world-fishing-827           # GFW production
export ANOMALY_PROJECT=anomaly-detection-demo-461518  # Demo project
export ANOMALY_PROJECT=your-project-id             # Your custom project
```

### Project-Specific Operations
All operations (DBT, Terraform, Docker) will use configurations from the active project directory:
- DBT seeds from `configs/$ANOMALY_PROJECT/dbt_seeds/`
- Dataloader configs from `configs/$ANOMALY_PROJECT/dataloader/`
- Terraform variables from `configs/$ANOMALY_PROJECT/terraform.tfvars`

## Adding a New Project

See `template/README.md` for detailed instructions on setting up a new project configuration.

## Architecture Benefits

- **Isolation**: Complete separation between projects
- **Reusability**: Same codebase works for any organization
- **Preservation**: Original configs remain untouched
- **Scalability**: Easy to add new projects without conflicts