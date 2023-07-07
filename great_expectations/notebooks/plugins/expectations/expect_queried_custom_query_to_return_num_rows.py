from typing import Optional, Union

from great_expectations.core.expectation_configuration import ExpectationConfiguration
from great_expectations.core.util import convert_to_json_serializable
from great_expectations.execution_engine import ExecutionEngine
from great_expectations.expectations.expectation import (
    ExpectationValidationResult,
    InvalidExpectationConfigurationError,
    QueryExpectation,
)


class ExpectQueriedCustomQueryToReturnNumRows(QueryExpectation):
    """Expect the number of rows returned from custom query to be equal to specified value.

    Args:
    template_dict: dict containing the following key: \
         user_query (user query. It must contain active_batch e.g. "select * from {active_batch}")
    """

    metric_dependencies = ("query.template_values",)

    query = """
            select count(1)
            from ({user_query}) as main
            """

    success_keys = (
        "template_dict",
        "query",
    )

    domain_keys = ("user_query", "batch_id", "row_condition", "condition_parser")

    default_kwarg_values = {
        "result_format": "BASIC",
        "include_config": True,
        "catch_exceptions": False,
        "meta": None,
        "value": "dummy_value",
        "query": query,
    }

    def _validate(
        self,
        configuration: ExpectationConfiguration,
        metrics: dict,
        runtime_configuration: dict = None,
        execution_engine: ExecutionEngine = None,
    ) -> Union[ExpectationValidationResult, dict]:
        metrics = convert_to_json_serializable(data=metrics)
        query_result = list(metrics.get("query.template_values")[0].values())[0]
        value = configuration["kwargs"].get("value")

        success = query_result == value

        return {
            "success": success,
            "result": {"observed_value": query_result},
        }

    examples = [
    {
        "data": [
            {
                "data": {
                    "col1": [1, 2, 2, 3, 4],
                    "col2": ["a", "a", "b", "b", "a"],
                },
            },
        ],
        "tests": [
            {
                "title": "basic_positive_test",
                "exact_match_out": False,
                "include_in_gallery": True,
                "in": {
                    "template_dict": {"user_query": "select * from {active_batch}"},
                    "value": 5,
                },
                "out": {"success": True},
                "only_for": ["bigquery"],
            },
            {
                "title": "basic_negative_test",
                "exact_match_out": False,
                "include_in_gallery": True,
                "in": {
                    "template_dict": {"user_query": "select * from {active_batch}"},
                    "value": 2,
                },
                "out": {"success": False},
                "only_for": ["bigquery"],
            },
            {
                "title": "positive_test_static_data_asset",
                "exact_match_out": False,
                "include_in_gallery": True,
                "in": {
                    "template_dict": {"user_query": "select * from {active_batch} limit 2"},
                    "value": 2,
                },
                "out": {"success": True},
                "only_for": ["bigquery"],
            },
        ],
    },
]

    library_metadata = {
        "tags": ["query-based"],
        "contributors": ["@mantasmy", "@itaise"],
    }

    def validate_configuration(
        self, configuration: Optional[ExpectationConfiguration] = None
    ) -> None:
        super().validate_configuration(configuration)
        value = configuration["kwargs"].get("value")

        try:
            assert value is not None, "'value' must be specified"
            assert (
                isinstance(value, int) and value >= 0
            ), "`value` must be an integer greater than or equal to zero"
        except AssertionError as e:
            raise InvalidExpectationConfigurationError(str(e))


if __name__ == "__main__":
    ExpectQueriedCustomQueryToReturnNumRows().print_diagnostic_checklist()
