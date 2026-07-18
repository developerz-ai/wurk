# frozen_string_literal: true

Rails.application.routes.draw do
  mount Wurk::Engine => '/wurk'
  # Second mount at a non-default path proves the dashboard is mount-agnostic:
  # the SPA reads window.__WURK_BASE__ (injected from request.script_name) rather
  # than a baked-in /wurk literal. Exercised by DashboardRoutesTest.
  mount Wurk::Engine => '/sidekiq', as: 'wurk_alt'
  root to: redirect('/wurk')
end
