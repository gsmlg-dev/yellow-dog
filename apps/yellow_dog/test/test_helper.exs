# Stop the yellow_dog application to prevent automatic Config agent startup
Application.stop(:yellow_dog)

ExUnit.start()
