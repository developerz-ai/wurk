# frozen_string_literal: true

Rails.application.routes.draw do
  # The dashboard, mounted read-only (see config/initializers/wurk.rb).
  mount Wurk::Engine => "/wurk"
  root to: redirect("/wurk")
end
