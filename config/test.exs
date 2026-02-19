import Config

if System.get_env("HIVEBEAM_GATEWAY_TOKEN") in [nil, ""] do
  System.put_env("HIVEBEAM_GATEWAY_TOKEN", "test-token")
end

if System.get_env("HIVEBEAM_GATEWAY_BIND") in [nil, ""] do
  System.put_env("HIVEBEAM_GATEWAY_BIND", "127.0.0.1:0")
end

if System.get_env("HIVEBEAM_GATEWAY_DATA_DIR") in [nil, ""] do
  path =
    Path.join(
      System.tmp_dir!(),
      "hivebeam_gateway_test_boot_#{System.unique_integer([:positive, :monotonic])}"
    )

  System.put_env("HIVEBEAM_GATEWAY_DATA_DIR", path)
end
