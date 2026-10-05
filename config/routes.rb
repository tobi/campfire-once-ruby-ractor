# frozen_string_literal: true

# Mirrors the reference config/routes.rb (Action Cable and the Active Storage URL
# contract are served by Cable/Storage directly from App).
Campfire::ROUTES = Campfire::Router.new do
  get "/", to: "WelcomeController#show", format: false

  get "/first_run", to: "FirstRunsController#show"
  post "/first_run", to: "FirstRunsController#create"

  get "/session/new", to: "SessionsController#new"
  post "/session", to: "SessionsController#create"
  delete "/session", to: "SessionsController#destroy"
  get "/session/transfers/:id", to: "Sessions::TransfersController#show"
  patch "/session/transfers/:id", to: "Sessions::TransfersController#update"
  put "/session/transfers/:id", to: "Sessions::TransfersController#update"

  get "/account/edit", to: "AccountsController#edit"
  patch "/account", to: "AccountsController#update"
  put "/account", to: "AccountsController#update"
  get "/account/users", to: "Accounts::UsersController#index"
  patch "/account/users/:id", to: "Accounts::UsersController#update"
  put "/account/users/:id", to: "Accounts::UsersController#update"
  delete "/account/users/:id", to: "Accounts::UsersController#destroy"
  get "/account/bots", to: "Accounts::BotsController#index"
  get "/account/bots/new", to: "Accounts::BotsController#new"
  post "/account/bots", to: "Accounts::BotsController#create"
  get "/account/bots/:id/edit", to: "Accounts::BotsController#edit"
  patch "/account/bots/:id", to: "Accounts::BotsController#update"
  put "/account/bots/:id", to: "Accounts::BotsController#update"
  delete "/account/bots/:id", to: "Accounts::BotsController#destroy"
  patch "/account/bots/:bot_id/key", to: "Accounts::Bots::KeysController#update"
  put "/account/bots/:bot_id/key", to: "Accounts::Bots::KeysController#update"
  post "/account/join_code", to: "Accounts::JoinCodesController#create"
  get "/account/logo", to: "Accounts::LogosController#show"
  delete "/account/logo", to: "Accounts::LogosController#destroy"
  get "/account/custom_styles/edit", to: "Accounts::CustomStylesController#edit"
  patch "/account/custom_styles", to: "Accounts::CustomStylesController#update"
  put "/account/custom_styles", to: "Accounts::CustomStylesController#update"

  get "/join/:join_code", to: "UsersController#new", format: false
  post "/join/:join_code", to: "UsersController#create", format: false

  get "/qr_code/:id", to: "QrCodeController#show"

  get "/users/:user_id/sidebar", to: "Users::SidebarsController#show"
  get "/users/:user_id/profile", to: "Users::ProfilesController#show"
  patch "/users/:user_id/profile", to: "Users::ProfilesController#update"
  put "/users/:user_id/profile", to: "Users::ProfilesController#update"
  get "/users/:user_id/push_subscriptions", to: "Users::PushSubscriptionsController#index"
  post "/users/:user_id/push_subscriptions", to: "Users::PushSubscriptionsController#create"
  delete "/users/:user_id/push_subscriptions/:id", to: "Users::PushSubscriptionsController#destroy"
  post "/users/:user_id/push_subscriptions/:push_subscription_id/test_notifications", to: "Users::PushSubscriptions::TestNotificationsController#create"
  get "/users/:user_id/avatar", to: "Users::AvatarsController#show"
  delete "/users/:user_id/avatar", to: "Users::AvatarsController#destroy"
  post "/users/:user_id/ban", to: "Users::BansController#create"
  delete "/users/:user_id/ban", to: "Users::BansController#destroy"
  get "/users/:id", to: "UsersController#show"

  get "/autocompletable/users", to: "Autocompletable::UsersController#index"

  get "/rooms/opens/new", to: "Rooms::OpensController#new"
  post "/rooms/opens", to: "Rooms::OpensController#create"
  get "/rooms/opens/:id/edit", to: "Rooms::OpensController#edit"
  patch "/rooms/opens/:id", to: "Rooms::OpensController#update"
  put "/rooms/opens/:id", to: "Rooms::OpensController#update"
  get "/rooms/opens/:id", to: "Rooms::OpensController#show"
  get "/rooms/closeds/new", to: "Rooms::ClosedsController#new"
  post "/rooms/closeds", to: "Rooms::ClosedsController#create"
  get "/rooms/closeds/:id/edit", to: "Rooms::ClosedsController#edit"
  patch "/rooms/closeds/:id", to: "Rooms::ClosedsController#update"
  put "/rooms/closeds/:id", to: "Rooms::ClosedsController#update"
  get "/rooms/closeds/:id", to: "Rooms::ClosedsController#show"
  get "/rooms/directs/new", to: "Rooms::DirectsController#new"
  post "/rooms/directs", to: "Rooms::DirectsController#create"
  get "/rooms/directs/:id/edit", to: "Rooms::DirectsController#edit"
  delete "/rooms/directs/:id", to: "Rooms::DirectsController#destroy"
  get "/rooms/directs/:id", to: "Rooms::DirectsController#show"

  get "/rooms", to: "RoomsController#index"
  get "/rooms/:room_id/messages", to: "MessagesController#index"
  post "/rooms/:room_id/messages", to: "MessagesController#create"
  get "/rooms/:room_id/messages/:id/edit", to: "MessagesController#edit"
  get "/rooms/:room_id/messages/:id", to: "MessagesController#show"
  patch "/rooms/:room_id/messages/:id", to: "MessagesController#update"
  put "/rooms/:room_id/messages/:id", to: "MessagesController#update"
  delete "/rooms/:room_id/messages/:id", to: "MessagesController#destroy"
  get "/rooms/:room_id/refresh", to: "Rooms::RefreshesController#show"
  get "/rooms/:room_id/settings", to: "Rooms::SettingsController#show"
  get "/rooms/:room_id/involvement", to: "Rooms::InvolvementsController#show"
  patch "/rooms/:room_id/involvement", to: "Rooms::InvolvementsController#update"
  put "/rooms/:room_id/involvement", to: "Rooms::InvolvementsController#update"
  get "/rooms/:room_id/@:message_id", to: "RoomsController#show"
  get "/rooms/:room_id/:bot_key/messages", to: "Messages::ByBotsController#index", defaults: { "format" => "json" }
  post "/rooms/:room_id/:bot_key/messages", to: "Messages::ByBotsController#create", defaults: { "format" => "json" }
  patch "/rooms/:room_id/:bot_key/messages/:id", to: "Messages::ByBotsController#update", defaults: { "format" => "json" }
  put "/rooms/:room_id/:bot_key/messages/:id", to: "Messages::ByBotsController#update", defaults: { "format" => "json" }
  delete "/rooms/:room_id/:bot_key/messages/:id", to: "Messages::ByBotsController#destroy", defaults: { "format" => "json" }
  post "/rooms/:room_id/:bot_key/messages/:message_id/boosts", to: "Messages::Boosts::ByBotsController#create", defaults: { "format" => "json" }
  delete "/rooms/:room_id/:bot_key/messages/:message_id/boosts/:id", to: "Messages::Boosts::ByBotsController#destroy", defaults: { "format" => "json" }
  get "/rooms/:id", to: "RoomsController#show"
  delete "/rooms/:id", to: "RoomsController#destroy"

  get "/messages/:message_id/boosts", to: "Messages::BoostsController#index"
  get "/messages/:message_id/boosts/new", to: "Messages::BoostsController#new"
  post "/messages/:message_id/boosts", to: "Messages::BoostsController#create"
  delete "/messages/:message_id/boosts/:id", to: "Messages::BoostsController#destroy"

  get "/searches", to: "SearchesController#index"
  post "/searches", to: "SearchesController#create"
  delete "/searches/clear", to: "SearchesController#clear"

  post "/unfurl_link", to: "UnfurlLinksController#create"

  get "/webmanifest", to: "PwaController#manifest"
  get "/service-worker", to: "PwaController#service_worker"

end
