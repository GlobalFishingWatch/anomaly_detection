# data-testing
Automated data testing

## Overview

### Great Expectations (GX/GE)
Great Expectations (GX/GE) allows to define expectation suites (a group of tests) in order to validate tables or subsets of tables.

More information in [great_expectations/README](great_expectations/README.md)

### Airflow
The [dags](dags) folder contains Airflow dags for running tests from Airflow.


### Dataset and table versioning
Great Expectations does not have a concept for table versions. Therefore, we define a [datasource config](great_expectations/datasources/datasources.yml) which maps different versions of the same table. That way, the same expectation suites can be run on different versions of the same table. This also allows running version related QA, e.g. in order to find and investigate differences.

## Usage

```
python3.9 -m venv venv
source venv/bin/activate
pip3 install -r requirements.txt
jupyter-lab
```

## Caveats
 - [ ] The current version of GX expectation suites must be run on a fork of Great Expectations that fixes [an issue when applying add_splitter_column_value on date columns](https://github.com/great-expectations/great_expectations/issues/8236)
 - [ ] Sharded tables are generally supported in GX but require further development in the code that generates data assets
 - [ ] The hack that automatically creates views to circumvent partition filter enforcement has not been tested on tables with non-date partition columns and further adjustment is probably necessary

## Data Doc sample
<img src="README.png" width="1200"/>

