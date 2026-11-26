# SPDX-License-Identifier: AGPL-3.0-only
class Api::V1::WasalxHealthController < ActionController::API
# Copyright (c) 2026 WasalX
  def show
    response.headers['Cache-Control'] = 'no-store'
    ready = ActiveRecord::Base.connection.select_value('SELECT 1').to_i == 1 &&
            Setting.get('system_init_done') == true
    head(ready ? :ok : :service_unavailable)
  rescue StandardError
    head :service_unavailable
  end
end
