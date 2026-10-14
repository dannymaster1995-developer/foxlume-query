/// EXPLAIN output captured from the local test servers: PostgreSQL 18.6, MySQL 8.4.9, SQLite 3.51 and DuckDB 1.5.6.
/// The tables are the sample data from `scripts/seed-*` (`perf_big` holds 2,000,000 rows).
enum ExplainFixtures {
    /// EXPLAIN (FORMAT JSON) of a join between users and orders with a filter.
    static let postgresJoin = ##"""
    [
      {
        "Plan": {
          "Node Type": "Nested Loop",
          "Parallel Aware": false,
          "Async Capable": false,
          "Join Type": "Inner",
          "Startup Cost": 0.15,
          "Total Cost": 14.99,
          "Plan Rows": 50,
          "Plan Width": 38,
          "Disabled": false,
          "Inner Unique": true,
          "Plans": [
            {
              "Node Type": "Seq Scan",
              "Parent Relationship": "Outer",
              "Parallel Aware": false,
              "Async Capable": false,
              "Relation Name": "orders",
              "Alias": "o",
              "Startup Cost": 0.00,
              "Total Cost": 7.12,
              "Plan Rows": 50,
              "Plan Width": 10,
              "Disabled": false,
              "Filter": "(status = 'paid'::text)"
            },
            {
              "Node Type": "Memoize",
              "Parent Relationship": "Inner",
              "Parallel Aware": false,
              "Async Capable": false,
              "Startup Cost": 0.15,
              "Total Cost": 1.13,
              "Plan Rows": 1,
              "Plan Width": 36,
              "Disabled": false,
              "Cache Key": "o.user_id",
              "Cache Mode": "logical",
              "Plans": [
                {
                  "Node Type": "Index Scan",
                  "Parent Relationship": "Outer",
                  "Parallel Aware": false,
                  "Async Capable": false,
                  "Scan Direction": "Forward",
                  "Index Name": "users_pkey",
                  "Relation Name": "users",
                  "Alias": "u",
                  "Startup Cost": 0.14,
                  "Total Cost": 1.12,
                  "Plan Rows": 1,
                  "Plan Width": 36,
                  "Disabled": false,
                  "Index Cond": "(id = o.user_id)"
                }
              ]
            }
          ]
        }
      }
    ]
    """##

    /// The same join with ANALYZE and BUFFERS: a nested loop over a Memoize node.
    static let postgresJoinAnalyze = ##"""
    [
      {
        "Plan": {
          "Node Type": "Nested Loop",
          "Parallel Aware": false,
          "Async Capable": false,
          "Join Type": "Inner",
          "Startup Cost": 0.15,
          "Total Cost": 14.99,
          "Plan Rows": 50,
          "Plan Width": 38,
          "Actual Startup Time": 0.112,
          "Actual Total Time": 0.130,
          "Actual Rows": 50.00,
          "Actual Loops": 1,
          "Disabled": false,
          "Inner Unique": true,
          "Shared Hit Blocks": 6,
          "Shared Read Blocks": 0,
          "Shared Dirtied Blocks": 0,
          "Shared Written Blocks": 0,
          "Local Hit Blocks": 0,
          "Local Read Blocks": 0,
          "Local Dirtied Blocks": 0,
          "Local Written Blocks": 0,
          "Temp Read Blocks": 0,
          "Temp Written Blocks": 0,
          "Plans": [
            {
              "Node Type": "Seq Scan",
              "Parent Relationship": "Outer",
              "Parallel Aware": false,
              "Async Capable": false,
              "Relation Name": "orders",
              "Alias": "o",
              "Startup Cost": 0.00,
              "Total Cost": 7.12,
              "Plan Rows": 50,
              "Plan Width": 10,
              "Actual Startup Time": 0.004,
              "Actual Total Time": 0.016,
              "Actual Rows": 50.00,
              "Actual Loops": 1,
              "Disabled": false,
              "Filter": "(status = 'paid'::text)",
              "Rows Removed by Filter": 200,
              "Shared Hit Blocks": 4,
              "Shared Read Blocks": 0,
              "Shared Dirtied Blocks": 0,
              "Shared Written Blocks": 0,
              "Local Hit Blocks": 0,
              "Local Read Blocks": 0,
              "Local Dirtied Blocks": 0,
              "Local Written Blocks": 0,
              "Temp Read Blocks": 0,
              "Temp Written Blocks": 0
            },
            {
              "Node Type": "Memoize",
              "Parent Relationship": "Inner",
              "Parallel Aware": false,
              "Async Capable": false,
              "Startup Cost": 0.15,
              "Total Cost": 1.13,
              "Plan Rows": 1,
              "Plan Width": 36,
              "Actual Startup Time": 0.002,
              "Actual Total Time": 0.002,
              "Actual Rows": 1.00,
              "Actual Loops": 50,
              "Disabled": false,
              "Cache Key": "o.user_id",
              "Cache Mode": "logical",
              "Cache Hits": 49,
              "Cache Misses": 1,
              "Cache Evictions": 0,
              "Cache Overflows": 0,
              "Peak Memory Usage": 1,
              "Shared Hit Blocks": 2,
              "Shared Read Blocks": 0,
              "Shared Dirtied Blocks": 0,
              "Shared Written Blocks": 0,
              "Local Hit Blocks": 0,
              "Local Read Blocks": 0,
              "Local Dirtied Blocks": 0,
              "Local Written Blocks": 0,
              "Temp Read Blocks": 0,
              "Temp Written Blocks": 0,
              "Plans": [
                {
                  "Node Type": "Index Scan",
                  "Parent Relationship": "Outer",
                  "Parallel Aware": false,
                  "Async Capable": false,
                  "Scan Direction": "Forward",
                  "Index Name": "users_pkey",
                  "Relation Name": "users",
                  "Alias": "u",
                  "Startup Cost": 0.14,
                  "Total Cost": 1.12,
                  "Plan Rows": 1,
                  "Plan Width": 36,
                  "Actual Startup Time": 0.004,
                  "Actual Total Time": 0.004,
                  "Actual Rows": 1.00,
                  "Actual Loops": 1,
                  "Disabled": false,
                  "Index Cond": "(id = o.user_id)",
                  "Rows Removed by Index Recheck": 0,
                  "Index Searches": 1,
                  "Shared Hit Blocks": 2,
                  "Shared Read Blocks": 0,
                  "Shared Dirtied Blocks": 0,
                  "Shared Written Blocks": 0,
                  "Local Hit Blocks": 0,
                  "Local Read Blocks": 0,
                  "Local Dirtied Blocks": 0,
                  "Local Written Blocks": 0,
                  "Temp Read Blocks": 0,
                  "Temp Written Blocks": 0
                }
              ]
            }
          ]
        },
        "Planning": {
          "Shared Hit Blocks": 262,
          "Shared Read Blocks": 0,
          "Shared Dirtied Blocks": 0,
          "Shared Written Blocks": 0,
          "Local Hit Blocks": 0,
          "Local Read Blocks": 0,
          "Local Dirtied Blocks": 0,
          "Local Written Blocks": 0,
          "Temp Read Blocks": 0,
          "Temp Written Blocks": 0
        },
        "Planning Time": 1.442,
        "Triggers": [
        ],
        "Execution Time": 0.167
      }
    ]
    """##

    /// ANALYZE of a filtered count over perf_big (2M rows): a parallel aggregate under a Gather.
    static let postgresParallelAnalyze = ##"""
    [
      {
        "Plan": {
          "Node Type": "Aggregate",
          "Strategy": "Plain",
          "Partial Mode": "Finalize",
          "Parallel Aware": false,
          "Async Capable": false,
          "Startup Cost": 30169.09,
          "Total Cost": 30169.10,
          "Plan Rows": 1,
          "Plan Width": 8,
          "Actual Startup Time": 20.422,
          "Actual Total Time": 21.414,
          "Actual Rows": 1.00,
          "Actual Loops": 1,
          "Disabled": false,
          "Shared Hit Blocks": 14139,
          "Shared Read Blocks": 4613,
          "Shared Dirtied Blocks": 0,
          "Shared Written Blocks": 0,
          "Local Hit Blocks": 0,
          "Local Read Blocks": 0,
          "Local Dirtied Blocks": 0,
          "Local Written Blocks": 0,
          "Temp Read Blocks": 0,
          "Temp Written Blocks": 0,
          "Plans": [
            {
              "Node Type": "Gather",
              "Parent Relationship": "Outer",
              "Parallel Aware": false,
              "Async Capable": false,
              "Startup Cost": 30168.87,
              "Total Cost": 30169.08,
              "Plan Rows": 2,
              "Plan Width": 8,
              "Actual Startup Time": 20.384,
              "Actual Total Time": 21.411,
              "Actual Rows": 3.00,
              "Actual Loops": 1,
              "Disabled": false,
              "Workers Planned": 2,
              "Workers Launched": 2,
              "Single Copy": false,
              "Shared Hit Blocks": 14139,
              "Shared Read Blocks": 4613,
              "Shared Dirtied Blocks": 0,
              "Shared Written Blocks": 0,
              "Local Hit Blocks": 0,
              "Local Read Blocks": 0,
              "Local Dirtied Blocks": 0,
              "Local Written Blocks": 0,
              "Temp Read Blocks": 0,
              "Temp Written Blocks": 0,
              "Plans": [
                {
                  "Node Type": "Aggregate",
                  "Strategy": "Plain",
                  "Partial Mode": "Partial",
                  "Parent Relationship": "Outer",
                  "Parallel Aware": false,
                  "Async Capable": false,
                  "Startup Cost": 29168.87,
                  "Total Cost": 29168.88,
                  "Plan Rows": 1,
                  "Plan Width": 8,
                  "Actual Startup Time": 19.162,
                  "Actual Total Time": 19.162,
                  "Actual Rows": 1.00,
                  "Actual Loops": 3,
                  "Disabled": false,
                  "Shared Hit Blocks": 14139,
                  "Shared Read Blocks": 4613,
                  "Shared Dirtied Blocks": 0,
                  "Shared Written Blocks": 0,
                  "Local Hit Blocks": 0,
                  "Local Read Blocks": 0,
                  "Local Dirtied Blocks": 0,
                  "Local Written Blocks": 0,
                  "Temp Read Blocks": 0,
                  "Temp Written Blocks": 0,
                  "Workers": [
                  ],
                  "Plans": [
                    {
                      "Node Type": "Seq Scan",
                      "Parent Relationship": "Outer",
                      "Parallel Aware": true,
                      "Async Capable": false,
                      "Relation Name": "perf_big",
                      "Alias": "perf_big",
                      "Startup Cost": 0.00,
                      "Total Cost": 29168.67,
                      "Plan Rows": 83,
                      "Plan Width": 0,
                      "Actual Startup Time": 0.494,
                      "Actual Total Time": 19.149,
                      "Actual Rows": 158.67,
                      "Actual Loops": 3,
                      "Disabled": false,
                      "Filter": "(payload ~~ 'abc%'::text)",
                      "Rows Removed by Filter": 666508,
                      "Shared Hit Blocks": 14139,
                      "Shared Read Blocks": 4613,
                      "Shared Dirtied Blocks": 0,
                      "Shared Written Blocks": 0,
                      "Local Hit Blocks": 0,
                      "Local Read Blocks": 0,
                      "Local Dirtied Blocks": 0,
                      "Local Written Blocks": 0,
                      "Temp Read Blocks": 0,
                      "Temp Written Blocks": 0,
                      "Workers": [
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        },
        "Planning": {
          "Shared Hit Blocks": 68,
          "Shared Read Blocks": 0,
          "Shared Dirtied Blocks": 0,
          "Shared Written Blocks": 0,
          "Local Hit Blocks": 0,
          "Local Read Blocks": 0,
          "Local Dirtied Blocks": 0,
          "Local Written Blocks": 0,
          "Temp Read Blocks": 0,
          "Temp Written Blocks": 0
        },
        "Planning Time": 0.105,
        "Triggers": [
        ],
        "Execution Time": 21.428
      }
    ]
    """##

    /// EXPLAIN FORMAT=JSON of the users/orders join.
    static let mysqlJoin = ##"""
    {
      "query_block": {
        "select_id": 1,
        "cost_info": {
          "query_cost": "31.50"
        },
        "nested_loop": [
          {
            "table": {
              "table_name": "o",
              "access_type": "ref",
              "possible_keys": [
                "orders_user_id_idx",
                "orders_status_idx"
              ],
              "key": "orders_status_idx",
              "used_key_parts": [
                "status"
              ],
              "key_length": "82",
              "ref": [
                "const"
              ],
              "rows_examined_per_scan": 50,
              "rows_produced_per_join": 50,
              "filtered": "100.00",
              "cost_info": {
                "read_cost": "9.00",
                "eval_cost": "5.00",
                "prefix_cost": "14.00",
                "data_read_per_join": "104K"
              },
              "used_columns": [
                "user_id",
                "status",
                "total"
              ]
            }
          },
          {
            "table": {
              "table_name": "u",
              "access_type": "eq_ref",
              "possible_keys": [
                "PRIMARY"
              ],
              "key": "PRIMARY",
              "used_key_parts": [
                "id"
              ],
              "key_length": "4",
              "ref": [
                "foxlume.o.user_id"
              ],
              "rows_examined_per_scan": 1,
              "rows_produced_per_join": 50,
              "filtered": "100.00",
              "cost_info": {
                "read_cost": "12.50",
                "eval_cost": "5.00",
                "prefix_cost": "31.50",
                "data_read_per_join": "100K"
              },
              "used_columns": [
                "id",
                "full_name"
              ]
            }
          }
        ]
      }
    }
    """##

    /// EXPLAIN ANALYZE of the same join, with engineering notation in the inner lookup.
    static let mysqlJoinAnalyze = ##"""
    -> Nested loop inner join  (cost=31.5 rows=50) (actual time=0.346..0.431 rows=50 loops=1)
        -> Index lookup on o using orders_status_idx (status='paid')  (cost=14 rows=50) (actual time=0.329..0.407 rows=50 loops=1)
        -> Single-row index lookup on u using PRIMARY (id=o.user_id)  (cost=0.252 rows=1) (actual time=372e-6..387e-6 rows=1 loops=50)
    """##

    /// Grouping and ordering wrappers around one table.
    static let mysqlGroup = ##"""
    {
      "query_block": {
        "select_id": 1,
        "cost_info": {
          "query_cost": "26.00"
        },
        "ordering_operation": {
          "using_temporary_table": true,
          "using_filesort": true,
          "grouping_operation": {
            "using_filesort": false,
            "table": {
              "table_name": "orders",
              "access_type": "index",
              "possible_keys": [
                "orders_status_idx"
              ],
              "key": "orders_status_idx",
              "used_key_parts": [
                "status"
              ],
              "key_length": "82",
              "rows_examined_per_scan": 250,
              "rows_produced_per_join": 83,
              "filtered": "33.33",
              "cost_info": {
                "read_cost": "17.67",
                "eval_cost": "8.33",
                "prefix_cost": "26.00",
                "data_read_per_join": "173K"
              },
              "used_columns": [
                "id",
                "status",
                "total"
              ],
              "attached_condition": "(`foxlume`.`orders`.`total` > 10.00)"
            }
          }
        }
      }
    }
    """##

    /// A UNION ALL of a derived table and a semi-join through a materialized subquery.
    static let mysqlUnion = ##"""
    {
      "query_block": {
        "union_result": {
          "using_temporary_table": false,
          "query_specifications": [
            {
              "dependent": false,
              "cacheable": true,
              "query_block": {
                "select_id": 1,
                "cost_info": {
                  "query_cost": "30.62"
                },
                "table": {
                  "table_name": "t",
                  "access_type": "ALL",
                  "rows_examined_per_scan": 250,
                  "rows_produced_per_join": 250,
                  "filtered": "100.00",
                  "cost_info": {
                    "read_cost": "5.62",
                    "eval_cost": "25.00",
                    "prefix_cost": "30.62",
                    "data_read_per_join": "23K"
                  },
                  "used_columns": [
                    "status",
                    "n"
                  ],
                  "materialized_from_subquery": {
                    "using_temporary_table": true,
                    "dependent": false,
                    "cacheable": true,
                    "query_block": {
                      "select_id": 2,
                      "cost_info": {
                        "query_cost": "26.00"
                      },
                      "grouping_operation": {
                        "using_filesort": false,
                        "table": {
                          "table_name": "orders",
                          "access_type": "index",
                          "possible_keys": [
                            "orders_status_idx"
                          ],
                          "key": "orders_status_idx",
                          "used_key_parts": [
                            "status"
                          ],
                          "key_length": "82",
                          "rows_examined_per_scan": 250,
                          "rows_produced_per_join": 250,
                          "filtered": "100.00",
                          "using_index": true,
                          "cost_info": {
                            "read_cost": "1.00",
                            "eval_cost": "25.00",
                            "prefix_cost": "26.00",
                            "data_read_per_join": "521K"
                          },
                          "used_columns": [
                            "id",
                            "status"
                          ]
                        }
                      }
                    }
                  }
                }
              }
            },
            {
              "dependent": false,
              "cacheable": true,
              "query_block": {
                "select_id": 3,
                "cost_info": {
                  "query_cost": "36.58"
                },
                "nested_loop": [
                  {
                    "table": {
                      "table_name": "users",
                      "access_type": "index",
                      "possible_keys": [
                        "PRIMARY"
                      ],
                      "key": "email",
                      "used_key_parts": [
                        "email"
                      ],
                      "key_length": "1022",
                      "rows_examined_per_scan": 5,
                      "rows_produced_per_join": 5,
                      "filtered": "100.00",
                      "using_index": true,
                      "cost_info": {
                        "read_cost": "0.25",
                        "eval_cost": "0.50",
                        "prefix_cost": "0.75",
                        "data_read_per_join": "10K"
                      },
                      "used_columns": [
                        "id",
                        "email"
                      ]
                    }
                  },
                  {
                    "table": {
                      "table_name": "<subquery4>",
                      "access_type": "eq_ref",
                      "key": "<auto_distinct_key>",
                      "key_length": "4",
                      "ref": [
                        "foxlume.users.id"
                      ],
                      "rows_examined_per_scan": 1,
                      "materialized_from_subquery": {
                        "using_temporary_table": true,
                        "query_block": {
                          "table": {
                            "table_name": "orders",
                            "access_type": "ALL",
                            "possible_keys": [
                              "orders_user_id_idx"
                            ],
                            "rows_examined_per_scan": 250,
                            "rows_produced_per_join": 83,
                            "filtered": "33.33",
                            "cost_info": {
                              "read_cost": "17.67",
                              "eval_cost": "8.33",
                              "prefix_cost": "26.00",
                              "data_read_per_join": "173K"
                            },
                            "used_columns": [
                              "user_id",
                              "total"
                            ],
                            "attached_condition": "(`foxlume`.`orders`.`total` > 100.00)"
                          }
                        }
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    }
    """##

    /// EXPLAIN FORMAT=JSON of a single-row UPDATE.
    static let mysqlUpdate = ##"""
    {
      "query_block": {
        "select_id": 1,
        "table": {
          "update": true,
          "table_name": "orders",
          "access_type": "range",
          "possible_keys": [
            "PRIMARY"
          ],
          "key": "PRIMARY",
          "used_key_parts": [
            "id"
          ],
          "key_length": "8",
          "ref": [
            "const"
          ],
          "rows_examined_per_scan": 1,
          "filtered": "100.00",
          "attached_condition": "(`foxlume`.`orders`.`id` = 3)"
        }
      }
    }
    """##

    /// EXPLAIN ANALYZE where the inner side never ran.
    static let mysqlNeverExecuted = ##"""
    -> Nested loop inner join  (cost=8.75 rows=50) (actual time=0.0228..0.0228 rows=0 loops=1)
        -> Filter: (u.full_name = 'nobody')  (cost=0.75 rows=1) (actual time=0.0225..0.0225 rows=0 loops=1)
            -> Table scan on u  (cost=0.75 rows=5) (actual time=0.0186..0.021 rows=5 loops=1)
        -> Index lookup on o using orders_user_id_idx (user_id=u.id)  (cost=8 rows=50) (never executed)
    """##

    /// EXPLAIN ANALYZE with a hash join, a temporary table and steps without a cost.
    static let mysqlHashJoinAnalyze = ##"""
    -> Limit: 10 row(s)  (actual time=0.106..0.106 rows=0 loops=1)
        -> Sort: top DESC, limit input to 10 row(s) per chunk  (actual time=0.106..0.106 rows=0 loops=1)
            -> Table scan on <temporary>  (actual time=0.0912..0.0912 rows=0 loops=1)
                -> Aggregate using temporary table  (actual time=0.091..0.091 rows=0 loops=1)
                    -> Filter: (u.full_name = o.notes)  (cost=127 rows=125) (actual time=0.0844..0.0844 rows=0 loops=1)
                        -> Inner hash join (<hash>(u.full_name)=<hash>(o.notes))  (cost=127 rows=125) (actual time=0.0841..0.0841 rows=0 loops=1)
                            -> Table scan on o  (cost=0.708 rows=250) (actual time=0.0125..0.0447 rows=250 loops=1)
                            -> Hash
                                -> Table scan on u  (cost=0.75 rows=5) (actual time=0.017..0.0209 rows=5 loops=1)
    """##

    /// EXPLAIN ANALYZE of a filtered count over perf_big: a full scan of 2M rows to keep 476.
    static let mysqlLargeScanAnalyze = ##"""
    -> Aggregate: count(0)  (cost=230648 rows=1) (actual time=294..294 rows=1 loops=1)
        -> Filter: (perf_big.payload like 'abc%')  (cost=208530 rows=221176) (actual time=0.92..294 rows=476 loops=1)
            -> Table scan on perf_big  (cost=208530 rows=1.99e+6) (actual time=0.0238..253 rows=2e+6 loops=1)
    """##

    /// EXPLAIN FORMAT=JSON with explain_json_format_version = 2 (MySQL 8.3 and later).
    static let mysqlVersionTwo = ##"""
    {
      "query": "/* select#1 */ select `u`.`full_name` AS `full_name`,`o`.`total` AS `total` from `foxlume`.`users` `u` join `foxlume`.`orders` `o` where ((`u`.`id` = `o`.`user_id`) and (`o`.`status` = 'paid'))",
      "inputs": [
        {
          "alias": "o",
          "covering": false,
          "operation": "Index lookup on o using orders_status_idx (status='paid')",
          "index_name": "orders_status_idx",
          "table_name": "orders",
          "access_type": "index",
          "schema_name": "foxlume",
          "used_columns": [
            "user_id",
            "status",
            "total"
          ],
          "estimated_rows": 50.0,
          "lookup_condition": "status='paid'",
          "index_access_type": "index_lookup",
          "estimated_total_cost": 8.0
        },
        {
          "alias": "u",
          "covering": false,
          "operation": "Single-row index lookup on u using PRIMARY (id=o.user_id)",
          "index_name": "PRIMARY",
          "table_name": "users",
          "access_type": "index",
          "schema_name": "foxlume",
          "used_columns": [
            "id",
            "full_name"
          ],
          "estimated_rows": 1.0,
          "lookup_condition": "id=o.user_id",
          "index_access_type": "index_lookup",
          "estimated_total_cost": 0.252
        }
      ],
      "join_type": "inner join",
      "operation": "Nested loop inner join",
      "query_type": "select",
      "access_type": "join",
      "estimated_rows": 50.0,
      "join_algorithm": "nested_loop",
      "estimated_total_cost": 25.5
    }
    """##

    /// EXPLAIN QUERY PLAN rows from the Chinook sample, tab-separated as the app flattens them.
    static let sqliteQueryPlan = ##"""
    8	0	91	SEARCH al USING INTEGER PRIMARY KEY (rowid=?)
    12	0	0	LIST SUBQUERY 1
    15	12	216	SCAN Track
    23	12	0	CREATE BLOOM FILTER
    31	0	45	SEARCH a USING INTEGER PRIMARY KEY (rowid=?)
    37	0	0	USE TEMP B-TREE FOR GROUP BY
    72	0	0	USE TEMP B-TREE FOR ORDER BY
    """##

    /// EXPLAIN (FORMAT JSON) of a grouped count.
    static let duckdbPlan = ##"""
    [
        {
            "name": "PROJECTION",
            "children": [
                {
                    "name": "PERFECT_HASH_GROUP_BY",
                    "children": [
                        {
                            "name": "PROJECTION",
                            "children": [
                                {
                                    "name": "PROJECTION",
                                    "children": [
                                        {
                                            "name": "SEQ_SCAN",
                                            "children": [],
                                            "extra_info": {
                                                "Table": "fq_explain.main.t",
                                                "Type": "Sequential Scan",
                                                "Projections": "g",
                                                "Filters": "id>10",
                                                "Estimated Cardinality": "20000"
                                            }
                                        }
                                    ],
                                    "extra_info": {
                                        "Projections": "__internal_compress_integral_utinyint(#0, 0)",
                                        "Estimated Cardinality": "20000"
                                    }
                                }
                            ],
                            "extra_info": {
                                "Projections": "g",
                                "Estimated Cardinality": "20000"
                            }
                        }
                    ],
                    "extra_info": {
                        "Groups": "#0",
                        "Aggregates": "count_star()"
                    }
                }
            ],
            "extra_info": {
                "Projections": [
                    "__internal_decompress_integral_bigint(#0, 0)",
                    "#1"
                ],
                "Estimated Cardinality": "7"
            }
        }
    ]
    """##

    /// EXPLAIN (ANALYZE, FORMAT JSON) of a join and grouped count.
    static let duckdbAnalyze = ##"""
    {
        "total_memory_allocated": 4980736,
        "total_bytes_written": 0,
        "total_bytes_read": 524288,
        "system_peak_temp_dir_size": 0,
        "system_peak_buffer_memory": 5996544,
        "rows_returned": 0,
        "result_set_size": 0,
        "latency": 0.00373175,
        "wal_replay_entry_count": 0,
        "extra_info": {},
        "commit_local_storage_latency": 0.0,
        "attach_load_storage_latency": 0.0,
        "query_name": "EXPLAIN (ANALYZE, FORMAT JSON) SELECT u.name, count(*) FROM t JOIN u ON t.g = u.g WHERE id > 10 GROUP BY u.name",
        "cpu_time": 0.002282010999999999,
        "checkpoint_latency": 0.0,
        "cumulative_cardinality": 399977,
        "waiting_to_attach_latency": 0.0,
        "write_to_wal_latency": 0.0,
        "attach_replay_wal_latency": 0.0,
        "blocked_thread_time": 0.0,
        "cumulative_rows_scanned": 100007,
        "children": [
            {
                "system_peak_temp_dir_size": 0,
                "result_set_size": 0,
                "operator_type": "EXPLAIN_ANALYZE",
                "operator_timing": 4.99e-7,
                "operator_rows_scanned": 0,
                "extra_info": {},
                "system_peak_buffer_memory": 0,
                "cumulative_rows_scanned": 100007,
                "cpu_time": 0.002282010999999999,
                "operator_name": "EXPLAIN_ANALYZE",
                "cumulative_cardinality": 399977,
                "operator_cardinality": 0,
                "children": [
                    {
                        "cumulative_cardinality": 399977,
                        "operator_cardinality": 7,
                        "cumulative_rows_scanned": 100007,
                        "operator_name": "PROJECTION",
                        "cpu_time": 0.002281511999999999,
                        "operator_rows_scanned": 0,
                        "system_peak_buffer_memory": 0,
                        "extra_info": {
                            "Projections": [
                                "__internal_decompress_string(#0)",
                                "#1"
                            ],
                            "Estimated Cardinality": "17682"
                        },
                        "operator_timing": 0.0000022500000000000005,
                        "system_peak_temp_dir_size": 0,
                        "result_set_size": 168,
                        "operator_type": "PROJECTION",
                        "children": [
                            {
                                "system_peak_temp_dir_size": 0,
                                "result_set_size": 84,
                                "operator_type": "HASH_GROUP_BY",
                                "operator_timing": 0.0009959219999999998,
                                "operator_rows_scanned": 0,
                                "extra_info": {
                                    "Groups": "#0",
                                    "Aggregates": "count_star()",
                                    "Estimated Cardinality": "17682"
                                },
                                "system_peak_buffer_memory": 0,
                                "cumulative_rows_scanned": 100007,
                                "cpu_time": 0.002279261999999999,
                                "operator_name": "HASH_GROUP_BY",
                                "cumulative_cardinality": 399970,
                                "operator_cardinality": 7,
                                "children": [
                                    {
                                        "cumulative_cardinality": 399963,
                                        "operator_cardinality": 99989,
                                        "cumulative_rows_scanned": 100007,
                                        "operator_name": "PROJECTION",
                                        "cpu_time": 0.0012833399999999994,
                                        "operator_rows_scanned": 0,
                                        "system_peak_buffer_memory": 0,
                                        "extra_info": {
                                            "Projections": "name",
                                            "Estimated Cardinality": "20000"
                                        },
                                        "operator_timing": 0.0000012509999999999995,
                                        "system_peak_temp_dir_size": 0,
                                        "result_set_size": 399956,
                                        "operator_type": "PROJECTION",
                                        "children": [
                                            {
                                                "system_peak_temp_dir_size": 0,
                                                "result_set_size": 499945,
                                                "operator_type": "PROJECTION",
                                                "operator_timing": 0.00006400200000000002,
                                                "operator_rows_scanned": 0,
                                                "extra_info": {
                                                    "Projections": [
                                                        "__internal_compress_integral_utinyint(#0, 0)",
                                                        "__internal_compress_string_uinteger(#1)"
                                                    ],
                                                    "Estimated Cardinality": "20000"
                                                },
                                                "system_peak_buffer_memory": 0,
                                                "cumulative_rows_scanned": 100007,
                                                "cpu_time": 0.0012820889999999993,
                                                "operator_name": "PROJECTION",
                                                "cumulative_cardinality": 299974,
                                                "operator_cardinality": 99989,
                                                "children": [
                                                    {
                                                        "cumulative_cardinality": 199985,
                                                        "operator_cardinality": 99989,
                                                        "cumulative_rows_scanned": 100007,
                                                        "operator_name": "HASH_JOIN",
                                                        "cpu_time": 0.0012180869999999992,
                                                        "operator_rows_scanned": 0,
                                                        "system_peak_buffer_memory": 0,
                                                        "extra_info": {
                                                            "Join Type": "INNER",
                                                            "Conditions": "g = g",
                                                            "Estimated Cardinality": "20000"
                                                        },
                                                        "operator_timing": 0.000357877,
                                                        "system_peak_temp_dir_size": 0,
                                                        "result_set_size": 2399736,
                                                        "operator_type": "HASH_JOIN",
                                                        "children": [
                                                            {
                                                                "system_peak_temp_dir_size": 0,
                                                                "result_set_size": 799912,
                                                                "operator_type": "TABLE_SCAN",
                                                                "operator_timing": 0.0004956689999999994,
                                                                "operator_rows_scanned": 100000,
                                                                "extra_info": {
                                                                    "Table": "fq_explain.main.t",
                                                                    "Type": "Sequential Scan",
                                                                    "Projections": "g",
                                                                    "Filters": "id>10",
                                                                    "Estimated Cardinality": "20000",
                                                                    "Dynamic Filters": "optional: g>=0 AND optional: g<=6"
                                                                },
                                                                "system_peak_buffer_memory": 0,
                                                                "cumulative_rows_scanned": 100000,
                                                                "cpu_time": 0.0004956689999999994,
                                                                "operator_name": "SEQ_SCAN",
                                                                "cumulative_cardinality": 99989,
                                                                "operator_cardinality": 99989,
                                                                "children": []
                                                            },
                                                            {
                                                                "system_peak_temp_dir_size": 0,
                                                                "result_set_size": 168,
                                                                "operator_type": "TABLE_SCAN",
                                                                "operator_timing": 0.00036454099999999996,
                                                                "operator_rows_scanned": 7,
                                                                "extra_info": {
                                                                    "Table": "fq_explain.main.u",
                                                                    "Type": "Sequential Scan",
                                                                    "Projections": [
                                                                        "g",
                                                                        "name"
                                                                    ],
                                                                    "Estimated Cardinality": "7"
                                                                },
                                                                "system_peak_buffer_memory": 0,
                                                                "cumulative_rows_scanned": 7,
                                                                "cpu_time": 0.00036454099999999996,
                                                                "operator_name": "SEQ_SCAN",
                                                                "cumulative_cardinality": 7,
                                                                "operator_cardinality": 7,
                                                                "children": []
                                                            }
                                                        ]
                                                    }
                                                ]
                                            }
                                        ]
                                    }
                                ]
                            }
                        ]
                    }
                ]
            }
        ]
    }
    """##
}
