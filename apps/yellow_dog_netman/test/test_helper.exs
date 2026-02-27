Application.put_env(:yellow_dog_netman, :netlink_backend, :mock)
Application.put_env(:yellow_dog_netman, :profile_dir, Path.join(__DIR__, "support/test_profiles"))

Application.put_env(
  :yellow_dog_netman,
  :socket_path,
  "/tmp/netman_test_#{:rand.uniform(65535)}.sock"
)

Application.put_env(:yellow_dog_netman, :reconciliation_interval_ms, 60_000)

ExUnit.start(exclude: [:integration, :privileged])
