# frozen_string_literal: true

Rails.application.routes.draw do
  mount Wurk::Engine => "/wurk"
  root to: redirect("/wurk")
end
