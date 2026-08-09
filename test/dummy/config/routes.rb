# frozen_string_literal: true

Rails.application.routes.draw do
  # Mount mode 2: the machine API on its own path, dashboard untouched.
  # Declared before the engine on purpose — Rails matches a mounted app by bare
  # string prefix, so `mount Wurk::Engine => '/wurk'` first also claims every
  # `/wurk-api/...` path, and its SPA catch-all answers the html-format ones
  # with the dashboard shell. Exercised by ApiMountModesTest.
  mount Wurk::API => '/wurk-api'
  mount Wurk::Engine => '/wurk'
  # Second mount at a non-default path proves the dashboard is mount-agnostic:
  # the SPA reads window.__WURK_BASE__ (injected from request.script_name) rather
  # than a baked-in /wurk literal. Exercised by DashboardRoutesTest.
  mount Wurk::Engine => '/sidekiq', as: 'wurk_alt'
  root to: redirect('/wurk')
end
