# Stop the yellow_dog application to prevent automatic Config agent startup
Application.stop(:yellow_dog)

ExUnit.start()

# Compile test support files
Code.require_file("support/config_helper.ex", __DIR__)
Code.require_file("support/store_helper.ex", __DIR__)
