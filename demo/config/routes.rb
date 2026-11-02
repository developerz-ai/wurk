# frozen_string_literal: true

Rails.application.routes.draw do
  # The dashboard, mounted read-only (see config/initializers/wurk.rb).
  mount Wurk::Engine => "/wurk"
  root to: redirect("/wurk")

  # The commit this image was built from. Demo-only, so the gem's own meta payload
  # stays free of it. deploy-demo.yml polls this to prove the new image is live.
  get "/demo/build", to: lambda { |_env|
    [200, { "content-type" => "application/json", "cache-control" => "no-store" },
     [{ sha: ENV.fetch("WURK_DEMO_BUILD_SHA", "") }.to_json]]
  }
end
