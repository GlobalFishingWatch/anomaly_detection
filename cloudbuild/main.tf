provider "google" {
  project = "world-fishing-827"
}

resource "google_cloudbuild_trigger" "trigger" {
  name     = "anomaly-detection-trigger"
  location = "global"

  github {
    name  = "anomaly_detection"
    owner = "GlobalFishingWatch"

    push {
      branch       = "^main|dev$"
      invert_regex = false
    }
  }

  build {
    step {
      name   = "hashicorp/terraform:1.1.5"
      script = <<EOF
        echo ''
        echo '*************** TERRAFORM INIT ******************'
        echo '*************************************************'
        cd deploy/dev
        terraform init -no-color || exit 1",
        EOF

    }
  }
}
