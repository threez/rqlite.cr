require "./spec_helper"

describe Rqlite::Connection::Options do
  describe ".from_uri" do
    it "parses host, port, and basic auth from the URI" do
      uri = URI.parse("rqlite://admin:secret@db.example.com:4001/")
      opts = Rqlite::Connection::Options.from_uri(uri)

      opts.host.should eq("db.example.com")
      opts.port.should eq(4001)
      opts.user.should eq("admin")
      opts.password.should eq("secret")
      opts.scheme.should eq("http")
    end

    it "defaults host/port when omitted" do
      uri = URI.parse("rqlite://")
      opts = Rqlite::Connection::Options.from_uri(uri)

      opts.host.should eq("localhost")
      opts.port.should eq(4001)
    end

    it "defaults level to weak, matching rqlite's own server-side default" do
      uri = URI.parse("rqlite://localhost:4001/")
      opts = Rqlite::Connection::Options.from_uri(uri)
      opts.level.should eq(Rqlite::Connection::Level::Weak)
    end

    it "parses an explicit level query param" do
      uri = URI.parse("rqlite://localhost:4001/?level=strong")
      opts = Rqlite::Connection::Options.from_uri(uri)
      opts.level.should eq(Rqlite::Connection::Level::Strong)
    end

    it "raises on an invalid level" do
      uri = URI.parse("rqlite://localhost:4001/?level=bogus")
      expect_raises(ArgumentError) { Rqlite::Connection::Options.from_uri(uri) }
    end

    it "forces https when scheme is rqlites" do
      uri = URI.parse("rqlites://localhost:4001/")
      opts = Rqlite::Connection::Options.from_uri(uri)
      opts.scheme.should eq("https")
    end

    it "forces https via the tls query param" do
      uri = URI.parse("rqlite://localhost:4001/?tls=true")
      opts = Rqlite::Connection::Options.from_uri(uri)
      opts.scheme.should eq("https")
    end

    it "parses freshness as a passthrough string" do
      uri = URI.parse("rqlite://localhost:4001/?freshness=5s")
      opts = Rqlite::Connection::Options.from_uri(uri)
      opts.freshness.should eq("5s")
    end

    it "defaults timeout to 30 seconds" do
      uri = URI.parse("rqlite://localhost:4001/")
      opts = Rqlite::Connection::Options.from_uri(uri)
      opts.timeout.should eq(30.seconds)
    end

    it "parses an explicit timeout query param as seconds" do
      uri = URI.parse("rqlite://localhost:4001/?timeout=5")
      opts = Rqlite::Connection::Options.from_uri(uri)
      opts.timeout.should eq(5.seconds)
    end
  end

  describe "#uri" do
    it "builds a scheme://host:port URI with no path or query" do
      opts = Rqlite::Connection::Options.new(scheme: "https", host: "db.example.com", port: 4001)
      opts.uri.should eq(URI.parse("https://db.example.com:4001"))
    end
  end
end
