ExUnit.start()

# Configure ExUnit for async testing when possible
ExUnit.configure(exclude: [integration: true, slow: true])
