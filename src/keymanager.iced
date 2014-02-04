
{constants} = require './constants'
{make_esc} = require 'iced-error'
{PackageJson} = require './package'
{init,master_ring} = require './keyring'
{env,init_env} = require './env'

#=====================================================

exports.KeyManager = class KeyManager

  #--------------

  constructor : ({@username, @config, @passphrase, @ring, @tsenc, @key, @fingerprint}) ->
    @ring or= master_ring()
    @key = null
    @lib = 
      KeyManager : require('kbpgp').KeyManager
      Encryptor : require('triplesec').Encryptor

  #--------------

  @generate : ({username, config, passphrase, ring}, cb) ->
    username or= env().get_username()
    config or= constants.keygen
    ring or= master_ring()
    km = new KeyManager { username, config, passphrase, ring }
    await km._gen defer err
    km = null if err?
    cb err, km

  #--------------

  _gen : (cb) ->
    esc = make_esc cb, "KeyGen::Gen"
    h = constants.canonical_host
    email = @username + "@#{h}"
    script = [
      "%echo generating"
      "Key-Type: RSA"
      "Key-Length: #{@config.master.bits}"
      "Subkey-Type: RSA"
      "Subkey-Length: #{@config.subkey.bits}"
      "Name-Real: #{h}/#{@username}"
      "Name-Email: #{email}"
      "Expire-date: #{@config.expire}"
      "Passphrase: #{@passphrase}"
      "%commit"
    ]
    stdin = script.join("\n")
    args = [ "--batch", "--gen-key" ]
    await @ring.gpg { args, stdin, quiet : true }, esc defer()
    @key = @ring.make_key { username : "<#{email}>", secret : true }
    await @key.load esc defer()
    cb null

  #--------------

  _load : (cb) ->
    await @ring.make_key { @fingerprint , secret : true }
    await @key.load defer err
    cb err

  #--------------

  @load : (opts, cb) ->
    km = new KeyManager opts
    await km._load defer err
    km = null if err?
    cb err, km

  #--------------

  load_public : (cb) ->
    pubkey = @ring.make_key { fingerprint : @key.fingerprint(), secret : false }
    await pubkey.load defer err
    @pubkey = pubkey unless err?
    cb err, pubkey

  #--------------

  get_tsenc : () ->
    unless @tsenc
      @tsenc = new @lib.Encryptor { key : new Buffer(@passphrase, 'utf8') }
    return @tsenc

  #--------------

  import_from_pgp : (cb) ->
    raw = @key.key_data().toString('utf8')
    await @lib.KeyManager.import_from_armored_pgp { raw }, defer err, @km, warnings
    @warn "Export to P3SKB format", warnings
    cb err

  #--------------

  unlock_pgp : ({passphrase,prompter}, cb) ->
    esc = make_esc cb, "KeyManager::unlock_pgp"
    passphrase or= @passphrase
    if @km.is_pgp_locked()
      if not passphrase?
        await prompter esc defer passphrase
        @passphrase = passphrase
      await @km.unlock_pgp { passphrase }, defer err
    cb err

  #--------------

  sign_and_export : (cb) ->
    esc = make_esc cb, "KeyManager::sign_and_export"
    await @km.sign {}, esc defer()
    await @km.export_private_to_server { tsenc : @get_tsenc() }, esc defer @p3skb
    cb null

  #--------------
 
  export_to_p3skb : ({prompter}, cb) ->
    esc = make_esc cb, "KeyManager::encrypt_to_p3skb"
    await @import_from_pgp esc defer()
    await @unlock_pgp {prompter}, esc defer()
    await @sign_and_export esc defer()
    cb null, @p3skb

  #--------------

  set_passphrase : (p) ->
    @passphrase = p
    @tsenc = null

  #--------------

  @import_from_p3skb : ({raw, ring, tsenc, passphrase}, cb) ->
    km = new KeyManager { ring, tsenc, passphrase }
    await km._import_from_p3skb {raw }, defer err
    km = null if err?
    cb err, km

  #--------------

  warn : (what, warnings) ->
    for w in warnings.warnings()
      log.warn "#{what}: #{w}"

  #--------------

  save_to_ring : ({passphrase, ring}, cb) ->
    esc = make_esc cb, "KeyManager::save_to_ring"
    @ring = ring if ring?
    @set_passphrase(passphrase) if passphrase?
    await @km.sign {}, esc defer()
    await @km.export_pgp_private_to_client { @passphrase }, esc defer key_data
    @key = @ring.make_key { key_data, fingerprint : @km.get_pgp_fingerprint() }
    await @key.save esc defer()
    cb null

  #--------------

  _import_from_p3skb : ({raw}, cb) ->
    esc = make_esc cb, "KeyManager::_import_from_p3skb"
    await @lib.KeyManager.import_from_p3skb { raw }, esc defer @km, warnings
    @warn "Import from P3SKB format", warnings
    if @km.is_p3skb_locked() and @passphrase?
      await @km.unlock_p3skb { tsenc : @get_tsenc() }, esc defer()
    cb null

#=====================================================