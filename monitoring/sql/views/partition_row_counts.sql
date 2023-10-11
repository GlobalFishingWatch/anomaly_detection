SELECT *, 'pipe3' as version
FROM `scratch_christian_homberg_ttl120d.partition_row_counts_pipe3`
UNION ALL
SELECT *, 'pipe2' as version
FROM `scratch_christian_homberg_ttl120d.partition_row_counts_pipe2`
UNION ALL
SELECT *, 'pipe3_backup' as version
FROM `scratch_christian_homberg_ttl120d.partition_row_counts_pipe3_backup`