# frozen_string_literal: true

require_relative '../../ports/grpc'
require_relative '../../adapters/nodes/node'
require_relative '../../adapters/edges/payment'
require_relative '../../adapters/invoice'
require_relative '../../adapters/edges/payment/purpose'

require_relative '../../models/edges/payment'

module Lighstorm
  module Controllers
    module Payment
      module All
        def self.fetch(purpose: nil, limit: nil)
          at = Time.now
          get_info = Ports::GRPC.lightning.get_info.to_h

          last_offset = 0

          payments = []

          loop do
            response = Ports::GRPC.lightning.list_payments(
              index_offset: last_offset
            )

            response.payments.each do |payment|
              payment = payment.to_h

              payment_purpose = Adapter::Purpose.list_payments(payment, get_info)

              case purpose
              when 'self-payment', 'self'
                payments << payment if payment_purpose == 'self-payment'
              when 'peer-to-peer', 'p2p'
                payments << payment if payment_purpose == 'peer-to-peer'
              when '!peer-to-peer', '!p2p'
                payments << payment unless payment_purpose == 'peer-to-peer'
              when 'rebalance'
                payments << payment if payment_purpose == 'rebalance'
              when '!rebalance'
                payments << payment unless payment_purpose == 'rebalance'
              when '!payment'
                payments << payment unless payment_purpose == 'payment'
              when 'payment'
                payments << payment if payment_purpose == 'payment'
              else
                payments << payment
              end
            end

            # TODO: How to optimize this?
            # break if !limit.nil? && payments.size >= limit

            break if last_offset == response.last_index_offset || last_offset > response.last_index_offset

            last_offset = response.last_index_offset
          end

          payments = payments.sort_by { |raw_payment| -raw_payment[:creation_time_ns] }

          payments = payments[0..limit - 1] unless limit.nil?

          data = {
            at: at,
            get_info: Ports::GRPC.lightning.get_info.to_h,
            fee_report: Ports::GRPC.lightning.fee_report.to_h,
            list_payments: payments,
            list_channels: {},
            get_chan_info: {},
            get_node_info: {},
            lookup_invoice: {},
            decode_pay_req: {}
          }

          payments.each do |payment|
            unless payment[:payment_request] == '' || data[:decode_pay_req][payment[:payment_request]]
              data[:decode_pay_req][payment[:payment_request]] = Ports::GRPC.lightning.decode_pay_req(
                pay_req: payment[:payment_request]
              ).to_h
            end

            unless data[:lookup_invoice][payment[:payment_hash]]
              begin
                data[:lookup_invoice][payment[:payment_hash]] = Ports::GRPC.lightning.lookup_invoice(
                  r_hash_str: payment[:payment_hash]
                ).to_h
              rescue StandardError => e
                data[:lookup_invoice][payment[:payment_hash]] = { _error: e }
              end
            end

            payment[:htlcs].each do |htlc|
              htlc[:route][:hops].each do |hop|
                unless data[:get_chan_info][hop[:chan_id]]
                  begin
                    data[:get_chan_info][hop[:chan_id]] = Ports::GRPC.lightning.get_chan_info(
                      chan_id: hop[:chan_id]
                    ).to_h
                  rescue GRPC::Unknown => e
                    data[:get_chan_info][hop[:chan_id]] = { _error: e }
                  end
                end

                next if data[:get_node_info][hop[:pub_key]]

                data[:get_node_info][hop[:pub_key]] = Ports::GRPC.lightning.get_node_info(
                  pub_key: hop[:pub_key]
                ).to_h
              end
            end
          end

          data[:lookup_invoice].each_value do |invoice|
            if invoice[:_error] || invoice[:payment_request] == '' || data[:decode_pay_req][invoice[:payment_request]]
              next
            end

            data[:decode_pay_req][invoice[:payment_request]] = Ports::GRPC.lightning.decode_pay_req(
              pay_req: invoice[:payment_request]
            ).to_h
          end

          list_channels_done = {}

          data[:get_chan_info].each_value do |channel|
            next if channel[:_error]

            partners = [channel[:node1_pub], channel[:node2_pub]]

            is_mine = partners.include?(data[:get_info][:identity_pubkey])

            if is_mine
              partner = partners.find { |p| p != data[:get_info][:identity_pubkey] }

              unless list_channels_done[partner]
                Ports::GRPC.lightning.list_channels(
                  peer: [partner].pack('H*')
                ).channels.map(&:to_h).each do |list_channels|
                  data[:list_channels][list_channels[:chan_id]] = list_channels
                end

                list_channels_done[partner] = true
              end
            end

            unless data[:get_node_info][channel[:node1_pub]]
              data[:get_node_info][channel[:node1_pub]] = Ports::GRPC.lightning.get_node_info(
                pub_key: channel[:node1_pub]
              ).to_h
            end

            next if data[:get_node_info][channel[:node2_pub]]

            data[:get_node_info][channel[:node2_pub]] = Ports::GRPC.lightning.get_node_info(
              pub_key: channel[:node2_pub]
            ).to_h
          end

          data[:list_channels].each_value do |channel|
            next if data[:get_node_info][channel[:remote_pubkey]]

            data[:get_node_info][channel[:remote_pubkey]] = Ports::GRPC.lightning.get_node_info(
              pub_key: channel[:remote_pubkey]
            ).to_h
          end

          data
        end

        def self.adapt(raw)
          adapted = {
            get_info: Lighstorm::Adapter::Node.get_info(raw[:get_info]),
            list_payments: raw[:list_payments].map do |raw_payment|
              Lighstorm::Adapter::Payment.list_payments(raw_payment, raw[:get_info])
            end,
            fee_report: raw[:fee_report][:channel_fees].map do |raw_fee|
              Lighstorm::Adapter::Fee.fee_report(raw_fee.to_h)
            end,
            lookup_invoice: {},
            list_channels: {},
            get_chan_info: {},
            get_node_info: {},
            decode_pay_req: {}
          }

          raw[:decode_pay_req].each_key do |key|
            next if raw[:decode_pay_req][key][:_error]

            adapted[:decode_pay_req][key] = Lighstorm::Adapter::PaymentRequest.decode_pay_req(
              raw[:decode_pay_req][key]
            )
          end

          raw[:lookup_invoice].each_key do |key|
            next if raw[:lookup_invoice][key][:_error]

            adapted[:lookup_invoice][key] = Lighstorm::Adapter::Invoice.lookup_invoice(
              raw[:lookup_invoice][key]
            )
          end

          raw[:get_chan_info].each_key do |key|
            next if raw[:get_chan_info][key][:_error]

            adapted[:get_chan_info][key] = Lighstorm::Adapter::Channel.get_chan_info(
              raw[:get_chan_info][key]
            )
          end

          raw[:list_channels].each_key do |key|
            adapted[:list_channels][key] = Lighstorm::Adapter::Channel.list_channels(
              raw[:list_channels][key], raw[:at]
            )
          end

          raw[:get_node_info].each_key do |key|
            adapted[:get_node_info][key] = Lighstorm::Adapter::Node.get_node_info(
              raw[:get_node_info][key]
            )
          end

          adapted
        end

        def self.transform_channel(data, adapted)
          if adapted[:get_chan_info][data[:id].to_i]
            target = data[:target]
            data = adapted[:get_chan_info][data[:id].to_i]
            data[:target] = target
            data[:known] = true
          else
            data[:_key] = Digest::SHA256.hexdigest(data[:id])
          end

          data[:mine] = true if data[:partners].size == 1

          [0, 1].each do |i|
            next unless data[:partners] && data[:partners][i]

            if data[:partners][i][:node][:public_key] == adapted[:get_info][:public_key]
              data[:partners][i][:node] = adapted[:get_info]
            end

            data[:partners].each do |partner|
              if data[:partners][i][:node][:public_key] == partner[:node][:public_key]
                data[:partners][i][:policy] = partner[:policy]
              end
            end

            if data[:partners][i][:node][:public_key] == adapted[:get_info][:public_key]
              data[:partners][i][:node][:platform] = adapted[:get_info][:platform]
              data[:partners][i][:node][:myself] = true
              data[:mine] = true
              adapted[:fee_report].each do |channel|
                next unless data[:id] == channel[:id]

                data[:partners][i][:policy][:fee] = channel[:partner][:policy][:fee]
                break
              end
            else
              data[:partners][i][:node] = adapted[:get_node_info][data[:partners][i][:node][:public_key]]
              data[:partners][i][:node][:platform] = {
                blockchain: adapted[:get_info][:platform][:blockchain],
                network: adapted[:get_info][:platform][:network]
              }

              data[:partners][i][:node][:myself] = false
            end
          end

          channel = adapted[:list_channels][data[:id].to_i]

          return data unless channel

          channel.each_key do |key|
            next if data.key?(key)

            data[key] = channel[key]
          end

          data[:accounting] = channel[:accounting]

          channel[:partners].each do |partner|
            data[:partners].each_index do |i|
              partner.each_key do |key|
                next if data[:partners][i].key?(key)

                data[:partners][i][key] = partner[key]
              end
            end
          end

          data
        end

        def self.transform(list_payments, adapted)
          if adapted[:lookup_invoice][list_payments[:request][:secret][:hash]] &&
             !adapted[:lookup_invoice][list_payments[:request][:secret][:hash]][:_error]

            list_payments[:request] = adapted[:lookup_invoice][list_payments[:request][:secret][:hash]][:request]
          else
            list_payments[:request][:_key] = Digest::SHA256.hexdigest(
              list_payments[:request][:code]
            )
          end
          list_payments[:hops].each do |hop|
            hop[:channel] = transform_channel(hop[:channel], adapted)
          end

          if adapted[:decode_pay_req][list_payments[:request][:code]]
            decoded = adapted[:decode_pay_req][list_payments[:request][:code]]
            request = list_payments[:request]

            decoded.each_key do |key|
              request[key] = decoded[key] unless request.key?(key)

              next unless decoded[key].is_a?(Hash)

              decoded[key].each_key do |sub_key|
                request[key][sub_key] = decoded[key][sub_key] unless request[key].key?(sub_key)
              end
            end
          end

          list_payments
        end

        def self.data(purpose: nil, limit: nil, &vcr)
          raw = if vcr.nil?
                  fetch(purpose: purpose, limit: limit)
                else
                  vcr.call(-> { fetch(purpose: purpose, limit: limit) })
                end

          adapted = adapt(raw)

          adapted[:list_payments].map do |data|
            transform(data, adapted)
          end
        end

        def self.model(data)
          data.map do |node_data|
            Lighstorm::Models::Payment.new(node_data)
          end
        end
      end
    end
  end
end
