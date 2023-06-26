#!/bin/bash

# Example script running checkpoint to be executed e.g. from CRON
# Usage in crontab:
# * * * * * bash /path/to/gx/project/run_satellite_timing_offsets_cp.sh /path/to/gx/project/

# We need to cd into the gx project which needs to be provided as a parameter
cd $1
source venv/bin/activate
great_expectations checkpoint run satellite_timing_offsets_hello_world_cp
