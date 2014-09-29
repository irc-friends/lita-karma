require "spec_helper"

describe Lita::Handlers::Karma, lita_handler: true do
  let(:payload) { double("payload") }

  before do
    Lita.config.handlers.karma.cooldown = nil
    described_class.routes.clear
    subject.define_routes(payload)
  end

  it { routes("foo++").to(:increment) }
  it { routes("foo--").to(:decrement) }
  it { routes("foo~~").to(:check) }
  it { routes_command("karma best").to(:list_best) }
  it { routes_command("karma worst").to(:list_worst) }
  it { routes_command("karma modified").to(:modified) }
  it { routes_command("karma delete").to(:delete) }
  it { routes_command("karma").to(:list_best) }
  it { routes_command("foo += bar").to(:link) }
  it { routes_command("foo -= bar").to(:unlink) }
  it { doesnt_route("+++++").to(:increment) }
  it { doesnt_route("-----").to(:decrement) }

  describe "#update_data" do
    before { subject.redis.flushdb }

    describe 'reverse links' do
      it "adds reverse link data for all linked terms" do
        subject.redis.sadd("links:foo", ["bar", "baz"])
        subject.upgrade_data(payload)
        expect(subject.redis.sismember("linked_to:bar", "foo")).to be(true)
        expect(subject.redis.sismember("linked_to:baz", "foo")).to be(true)
      end

      it "skips the update if it's already been done" do
        expect(subject.redis).to receive(:keys).once.and_return([])
        subject.upgrade_data(payload)
        subject.upgrade_data(payload)
      end
    end

    describe 'modified counts' do
      before do
        subject.redis.zadd('terms', 2, 'foo')
        subject.redis.sadd('modified:foo', %w{bar baz})
      end

      it 'gives every modifier a single point' do
        subject.upgrade_data(payload)
        expect(subject.redis.type('modified:foo')).to eq 'zset'
        expect(subject.redis.zrange('modified:foo', 0, -1, with_scores: true)).to eq [['bar', 1.0], ['baz', 1.0]]
      end

      it "skips the update if it's already been done" do
        expect(subject.redis).to receive(:zrange).once.and_return([])
        subject.upgrade_data(payload)
        subject.upgrade_data(payload)
      end

      it 'uses the upgrade Proc, if configured' do
        Lita.config.handlers.karma.upgrade_modified = Proc.new do |score, uids|
          uids.sort.each_with_index.map {|u, i| [i * score, u]}
        end

        subject.upgrade_data(payload)
        expect(subject.redis.zrange('modified:foo', 0, -1, with_scores: true)).to eq [['bar', 0.0], ['baz', 2.0]]
      end
    end

    describe 'score decay' do
      before do
        Lita.config.handlers.karma.decay = true
        Lita.config.handlers.karma.decay_interval = 24 * 60 * 60
      end

      it 'creates actions to match the current scores' do
        subject.redis.zadd('terms', 2, 'foo')
        subject.redis.sadd('modified:foo', %w{bar baz})
        subject.upgrade_data(payload)
        expect(subject.redis.zcard('actions')).to be(2)
      end

      it 'creates actions for every counted modification' do
        subject.redis.zadd('terms', 5, 'foo')
        subject.redis.zadd('modified:foo', {bar: 2, baz: 3}.invert.to_a)
        subject.upgrade_data(payload)
        expect(subject.redis.zcard('actions')).to be(5)
      end

      it 'spreads actions out using the decay_distributor Proc' do
        Lita.config.handlers.karma.decay_distributor = Proc.new {|i, count| 1000 * (i + 1) }
        subject.redis.zadd('terms', 5, 'foo')
        subject.redis.zadd('modified:foo', {bar: 2, baz: 3}.invert.to_a)
        time = Time.now
        subject.upgrade_data(payload)
        actions = subject.redis.zrange('actions', 0, -1, with_scores: true)

        # bar gets 1k & 2k, baz get 3k, 2k, & 1k
        [3,2,2,1,1].zip(actions.map(&:last)).each do |expectation, value|
          expect((time - value).to_f).to be_within(100).of(expectation * 1000)
        end
      end

      it 'creates anonymous actions for the unknown modifications' do
        subject.redis.zadd('terms', 50, 'foo')
        subject.redis.zadd('modified:foo', {bar: 2, baz: 3}.invert.to_a)
        subject.upgrade_data(payload)
        expect(subject.redis.zcard('actions')).to be(50)
      end

      it 'only creates missing actions' do
        subject.redis.zadd('terms', 7, 'foo')
        subject.redis.zadd('modified:foo', {bar: 2, baz: 3}.invert.to_a)
        [:bar, :baz, nil].each {|mod| subject.send(:add_action, 'foo', mod)}
        subject.upgrade_data(payload)
        expect(subject.redis.zcard('actions')).to be(7)
      end

      it 'skips if the actions are up-to-date' do
        expect(subject.redis).to receive(:zrange).thrice.and_return([])
        subject.upgrade_data(payload)
        subject.upgrade_data(payload)
      end
    end
  end

  describe "#increment" do
    it "increases the term's score by one and says the new score" do
      send_message("foo++")
      expect(replies.last).to eq("foo: 1")
    end

    it "matches multiple terms in one message" do
      send_message("foo++ bar++")
      expect(replies).to eq(["foo: 1", "bar: 1"])
    end

    it "doesn't start from zero if the term already has a positive score" do
      send_message("foo++")
      send_message("foo++")
      expect(replies.last).to eq("foo: 2")
    end

    it "replies with a warning if term increment is on cooldown" do
      Lita.config.handlers.karma.cooldown = 10
      send_message("foo++")
      send_message("foo++")
      expect(replies.last).to match(/cannot modify foo/)
    end

    it "is case insensitive" do
      send_message("foo++")
      send_message("FOO++")
      expect(replies.last).to eq("foo: 2")
    end

    it "handles Unicode word characters" do
      send_message("föö++")
      expect(replies.last).to eq("föö: 1")
    end

    it "processes decay" do
      expect(subject).to receive(:process_decay).at_least(:once)
      send_message("foo++")
    end
  end

  describe "#decrement" do
    it "decreases the term's score by one and says the new score" do
      send_message("foo--")
      expect(replies.last).to eq("foo: -1")
    end

    it "matches multiple terms in one message" do
      send_message("foo-- bar--")
      expect(replies).to eq(["foo: -1", "bar: -1"])
    end

    it "doesn't start from zero if the term already has a positive score" do
      send_message("foo++")
      send_message("foo--")
      expect(replies.last).to eq("foo: 0")
    end

    it "replies with a warning if term increment is on cooldown" do
      Lita.config.handlers.karma.cooldown = 10
      send_message("foo--")
      send_message("foo--")
      expect(replies.last).to match(/cannot modify foo/)
    end

    it "processes decay" do
      expect(subject).to receive(:process_decay).at_least(:once)
      send_message("foo--")
    end
  end

  describe "#check" do
    it "says the term's current score" do
      send_message("foo~~")
      expect(replies.last).to eq("foo: 0")
    end

    it "matches multiple terms in one message" do
      send_message("foo~~ bar~~")
      expect(replies).to eq(["foo: 0", "bar: 0"])
    end

    it "processes decay" do
      expect(subject).to receive(:process_decay).at_least(:once)
      send_message("foo~~")
    end
  end

  describe "#list" do
    it "replies with a warning if there are no terms" do
      send_command("karma")
      expect(replies.last).to match(/no terms being tracked/)
    end

    context "with modified terms" do
      before do
        send_message(
          "one++ one++ one++ two++ two++ three++ four++ four-- five--"
        )
      end

      it "lists the top 5 terms by default" do
        send_command("karma")
        expect(replies.last).to eq <<-MSG.chomp
1. one (3)
2. two (2)
3. three (1)
4. four (0)
5. five (-1)
MSG
      end

      it 'lists the bottom 5 terms when passed "worst"' do
        send_command("karma worst")
        expect(replies.last).to eq <<-MSG.chomp
1. five (-1)
2. four (0)
3. three (1)
4. two (2)
5. one (3)
MSG
      end

      it "limits the list to the count passed as the second argument" do
        send_command("karma best 2")
        expect(replies.last).to eq <<-MSG.chomp
1. one (3)
2. two (2)
MSG
      end

      it "processes decay" do
        expect(subject).to receive(:process_decay).at_least(:once)
        send_command("karma best 2")
      end
    end
  end

  describe "#link" do
    it "says that it's linked term 2 to term 1" do
      send_command("foo += bar")
      expect(replies.last).to eq("bar has been linked to foo.")
    end

    it "says that term 2 was already linked to term 1 if it was" do
      send_command("foo += bar")
      send_command("foo += bar")
      expect(replies.last).to eq("bar is already linked to foo.")
    end

    it "causes term 1's score to be modified by term 2's" do
      send_message("foo++ bar++ baz++")
      send_command("foo += bar")
      send_command("foo += baz")
      send_message("foo~~")
      expect(replies.last).to match(
        /foo: 3 \(1\), linked to: ba[rz]: 1, ba[rz]: 1/
      )
    end
  end

  describe "#unlink" do
    it "says that it's unlinked term 2 from term 1" do
      send_command("foo += bar")
      send_command("foo -= bar")
      expect(replies.last).to eq("bar has been unlinked from foo.")
    end

    it "says that term 2 was not linked to term 1 if it wasn't" do
      send_command("foo -= bar")
      expect(replies.last).to eq("bar is not linked to foo.")
    end

    it "causes term 1's score to stop being modified by term 2's" do
      send_message("foo++ bar++")
      send_command("foo += bar")
      send_command("foo -= bar")
      send_message("foo~~")
      expect(replies.last).to eq("foo: 1")
    end
  end

  describe "#modified" do
    it "replies with the required format if a term is not provided" do
      send_command("karma modified")
      expect(replies.last).to match(/^Format:/)
    end

    it "replies with the required format if the term is an empty string" do
      send_command("karma modified '   '")
      expect(replies.last).to match(/^Format:/)
    end

    it "replies with a message if the term hasn't been modified" do
      send_command("karma modified foo")
      expect(replies.last).to match(/never been modified/)
    end

    it "lists users who have modified the given term in count order" do
      other_user = Lita::User.create("2", name: "Other User")
      send_message("foo++", as: user)
      send_message("foo++", as: user)
      send_message("foo++", as: other_user)
      send_command("karma modified foo")
      expect(replies.last).to eq("#{user.name} (2), #{other_user.name} (1)")
    end

    it "processes decay" do
      expect(subject).to receive(:process_decay).at_least(:once)
      send_command("karma modified foo")
    end
  end

  describe "#delete" do
    before do
      allow(Lita::Authorization).to receive(:user_in_group?).and_return(true)
    end

    it "deletes the term" do
      send_message("foo++")
      send_command("karma delete foo")
      expect(replies.last).to eq("foo has been deleted.")
      send_message("foo~~")
      expect(replies.last).to eq("foo: 0")
    end

    it "replies with a warning if the term doesn't exist" do
      send_command("karma delete foo")
      expect(replies.last).to eq("foo does not exist.")
    end

    it "matches terms exactly, including leading whitespace" do
      term = "  'foo bar* 'baz''/ :"
      subject.redis.zincrby("terms", 1, term)
      send_command("karma delete #{term}")
      expect(replies.last).to include("has been deleted")
    end

    it "clears the modification list" do
      send_message("foo++")
      send_command("karma delete foo")
      send_command("karma modified foo")
      expect(replies.last).to eq("foo has never been modified.")
    end

    it "clears the deleted term's links" do
      send_command("foo += bar")
      send_command("foo += baz")
      send_command("karma delete foo")
      send_message("foo++")
      expect(replies.last).to eq("foo: 1")
    end

    it "clears links from other terms connected to the deleted term" do
      send_command("bar += foo")
      send_command("baz += foo")
      send_command("karma delete foo")
      send_message("bar++")
      expect(replies.last).to eq("bar: 1")
      send_message("baz++")
      expect(replies.last).to eq("baz: 1")
    end
  end

  describe '#process_decay' do
    let(:mods) { {bar: 2, baz: 3, nil => 4} }
    let(:offsets) { {} }
    let(:term) { :foo }
    before do
      Lita.config.handlers.karma.decay = true
      Lita.config.handlers.karma.decay_interval = 24 * 60 * 60

      subject.redis.zadd('terms', 8, term)
      subject.redis.zadd("modified:#{term}", mods.invert.to_a)
      mods.each do |mod, score|
        offset = offsets[mod].to_i
        score.times do |i|
          subject.send(:add_action, term, mod, 1, Time.now - (i+offset) * 24 * 60 * 60)
        end
      end
    end

    it 'should decrement scores' do
      subject.send(:process_decay)
      expect(subject.redis.zscore(:terms, term).to_i).to be(2)
    end

    it 'should remove decayed actions' do
      subject.send(:process_decay)
      expect(subject.redis.zcard(:actions).to_i).to be(3)
    end

    context 'with decayed modifiers' do
      let(:offsets) { {baz: 1} }

      it 'should remove them' do
        subject.send(:process_decay)
        expect(subject.redis.zcard("modified:#{term}")).to be(2)
      end
    end
  end

  describe "custom term patterns and normalization" do
    before do
      Lita.config.handlers.karma.term_pattern = /[<:]([^>:]+)[>:]/
      Lita.config.handlers.karma.term_normalizer = lambda do |term|
        term.to_s.downcase.strip.sub(/[<:]([^>:]+)[>:]/, '\1')
      end
      described_class.routes.clear
      subject.define_routes(payload)
    end

    it "increments multi-word terms bounded by delimeters" do
      send_message(":Some Thing:++")
      expect(replies.last).to eq("some thing: 1")
    end

    it "increments terms with symbols that are bounded by delimeters" do
      send_message("<C++>++")
      expect(replies.last).to eq("c++: 1")
    end

    it "decrements multi-word terms bounded by delimeters" do
      send_message(":Some Thing:--")
      expect(replies.last).to eq("some thing: -1")
    end

    it "checks multi-word terms bounded by delimeters" do
      send_message(":Some Thing:~~")
      expect(replies.last).to eq("some thing: 0")
    end
  end
end
