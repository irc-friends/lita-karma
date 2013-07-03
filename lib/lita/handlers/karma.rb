require "lita"

module Lita
  module Handlers
    class Karma < Handler
      route %r{([^\s]{2,})\+\+}, :increment, help: { "TERM++" => "Increments TERM by one." }
      route %r{([^\s]{2,})\-\-}, :decrement, help: { "TERM--" => "Decrements TERM by one." }
      route %r{([^\s]{2,})~~}, :check, help: { "TERM~~" => "Shows the current karma of TERM." }
      route %r{^karma\s+worst}, :list_worst, command: true, help: {
        "karma worst [N]" => "Lists the bottom N terms by karma. N defaults to 5."
      }
      route %r{^karma\s+best}, :list_best, command: true, help: {
        "karma best [N]" => "Lists the top N terms by karma. N defaults to 5."
      }
      route %r{^karma\s+modified}, :modified, command: true, help: {
        "karma modified TERM" => "Lists the names of users who have upvoted or downvoted TERM."
      }
      route %r{^karma\s*$}, :list_best, command: true
      route %r{^([^\s]{2,})\s*\+=\s*([^\s]{2,})}, :link, command: true, help: {
        "TERM1 += TERM2" => "Links TERM2 to TERM1. TERM1's karma will then be displayed as the sum of its own and TERM2's karma."
      }
      route %r{^([^\s]{2,})\s*-=\s*([^\s]{2,})}, :unlink, command: true, help: {
        "TERM1 -= TERM2" => "Unlinks TERM2 from TERM1. TERM1's karma will no longer be displayed as the sum of its own and TERM2's karma."
      }

      def increment(response)
        modify(response, 1)
      end

      def decrement(response)
        modify(response, -1)
      end

      def check(response)
        output = []

        response.matches.each do |match|
          term = match[0]
          own_score = score = redis.zscore("terms", term).to_i
          links = []
          redis.smembers("links:#{term}").each do |link|
            link_score = redis.zscore("terms", link).to_i
            links << "#{link}: #{link_score}"
            score += link_score
          end

          string = "#{term}: #{score}"
          unless links.empty?
            string << " (#{own_score}), linked to: "
            string << links.join(", ")
          end
          output << string
        end

        response.reply *output
      end

      def list_best(response)
        list(response, :zrevrange)
      end

      def list_worst(response)
        list(response, :zrange)
      end

      def link(response)
        response.matches.each do |match|
          term1, term2 = match

          if redis.sadd("links:#{term1}", term2)
            response.reply "#{term2} has been linked to #{term1}."
          else
            response.reply "#{term2} is already linked to #{term1}."
          end
        end
      end

      def unlink(response)
        response.matches.each do |match|
          term1, term2 = match

          if redis.srem("links:#{term1}", term2)
            response.reply "#{term2} has been unlinked from #{term1}."
          else
            response.reply "#{term2} is not linked to #{term1}."
          end
        end
      end

      def modified(response)
        term = response.args[1]

        if term.nil? || term.strip.empty?
          response.reply "Format: #{robot.name}: karma modified TERM"
          return
        end

        user_ids = redis.smembers("modified:#{term}")

        if user_ids.empty?
          response.reply "#{term} has never been modified."
        else
          output = user_ids.map do |id|
            User.find_by_id(id).name
          end.join(", ")
          response.reply output
        end
      end

      private

      def modify(response, delta)
        response.matches.each do |match|
          term = match[0]

          ttl = redis.ttl("cooldown:#{response.user.id}:#{term}")
          if ttl >= 0
            cooldown_message =
              "You cannot modify #{term} for another #{ttl} second"
            cooldown_message << (ttl == 1 ? "." : "s.")
            response.reply cooldown_message
            return
          else
            redis.zincrby("terms", delta, term)
            redis.sadd("modified:#{term}", response.user.id)
            cooldown = Lita.config.handlers.karma.cooldown
            if cooldown
              redis.setex(
                "cooldown:#{response.user.id}:#{term}",
                cooldown.to_i,
                1
              )
            end
          end
        end

        check(response)
      end

      def list(response, redis_command)
        n = (response.args[1] || 5).to_i - 1

        terms_scores = redis.public_send(
          redis_command, "terms", 0, n, with_scores: true
        )

        output = terms_scores.each_with_index.map do |term_score, index|
          "#{index + 1}. #{term_score[0]} (#{term_score[1].to_i})"
        end.join("\n")

        if output.length == 0
          response.reply "There are no terms being tracked yet."
        else
          response.reply output
        end
      end
    end

    Lita.config.handlers.karma = Config.new
    Lita.config.handlers.karma.cooldown = 300
    Lita.register_handler(Karma)
  end
end
