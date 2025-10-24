defmodule SofiTrader.Repo do
  use Ecto.Repo,
    otp_app: :sofi_trader,
    adapter: Ecto.Adapters.Postgres
end
