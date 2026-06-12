# Replay fixtures

JSON snapshots of deltas rows, used by the `--replay` CLI flag for dry-run
verification of the state machine. Generate with:

```
bq query --project_id=world-fishing-827 --use_legacy_sql=false --format=json \
  "SELECT * FROM \`world-fishing-827.tech_anomaly_detection.t_dev_deltas\`
   WHERE config_name = '<config>'
     AND timestamp BETWEEN '<start>' AND '<end>'" \
  > <name>.json
```

Each fixture is a top-level JSON array of row objects.
