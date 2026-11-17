# SPDX-License-Identifier: AGPL-3.0-only
# Delegated requests contain customer content and verified human assurance.
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
Rails.application.config.filter_parameters += %i[input actor assurance file]
