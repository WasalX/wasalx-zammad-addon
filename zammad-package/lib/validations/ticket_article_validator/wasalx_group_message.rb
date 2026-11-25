# SPDX-License-Identifier: AGPL-3.0-only

class Validations::TicketArticleValidator
  class WasalxGroupMessage < Default
    MATCHING_TYPES = ['wasalx group message'].freeze

    def validate_body
      # Zammad stages unsaved attachments in the same buffer used by its WhatsApp validator.
      return if record.body.present? || record.instance_variable_get(:@attachments_buffer).present? || record.attachments.present?

      super
    end
  end
end
