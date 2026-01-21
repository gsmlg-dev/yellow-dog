# Exclude tests that require actual database files unless running with --include requires_database
ExUnit.configure(exclude: [:requires_database])
ExUnit.start()
