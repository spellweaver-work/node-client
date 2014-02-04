{Base} = require './base'
log = require '../log'
{ArgumentParser} = require 'argparse'
{add_option_dict} = require './argparse'
{PackageJson} = require '../package'
session = require '../session'
{make_esc} = require 'iced-error'
{prompt_for_int} = require '../prompter'
log = require '../log'
{key_select} = require '../keyselector'
{KeybasePushProofGen} = require '../sigs'
req = require '../req'
{env} = require '../env'
{prompt_passphrase} = require '../prompter'
{KeyManager} = require '../keymanager'
{E} = require '../err'
{athrow} = require('iced-utils').util

##=======================================================================

exports.Command = class Command extends Base

  #----------

  OPTS :
    g :
      alias : "gen"
      action : "storeTrue"
      help : "generate a new key"
    s :
      alias : "push-secret"
      action : "storeTrue"
      help : "push the secret key to the server"

  #----------

  use_session : () -> true

  #----------

  add_subcommand_parser : (scp) ->
    opts = 
      aliases  : []
      help : "push a PGP key from the client to the server"
    name = "push"
    sub = scp.addParser name, opts
    add_option_dict sub, @OPTS
    sub.addArgument [ "search" ], { nargs : '?' }
    return opts.aliases.concat [ name ]

  #----------

  sign : (cb) ->
    eng = new KeybasePushProofGen { km : @key }
    await eng.run defer err, @sig
    cb err

  #----------

  push : (cb) ->
    args = 
      is_primary : 1
      sig : @sig.pgp
      sig_id_base : @sig.id
      sig_id_short : @sig.short_id
      public_key : @key.key_data().toString('utf8')
    args.private_key = @p3skb if @p3skb
    await req.post { endpoint : "key/add", args }, defer err
    cb err

  #----------

  load_key_manager : (cb) ->
    esc = make_esc cb, "KeyManager::load_secret"
    await KeyManager.load { fingerprint : @key.fingerprint() }, esc defer @keymanager
    cb null

  #----------

  package_secret_key : (cb) ->
    log.debug "+ package secret key"
    prompter = @prompt_passphrase.bind(@)
    await @keymanager.export_to_p3skb { prompter }, defer err, p3skb
    @p3skb = p3skb unless err?
    log.debug "- package secret key -> #{err?.message}"
    cb err

  #----------

  prompt_passphrase : (cb) ->
    args = 
      prompt : "Your key passphrase"
    await prompt_passphrase args, defer err, pp
    cb err, pp

  #----------

  prompt_new_passphrase : (cb) ->
    args = 
      prompt : "Your key passphrase (can be the same as your login passphrase)"
      confirm : prompt: "Repeat to confirm"
    await prompt_passphrase args, defer err, pp
    cb err, pp

  #----------

  do_key_gen : (cb) ->
    esc = make_esc cb, "do_key_gen"
    if @argv.search?
      athrow (new E.ArgsError "Cannot provide a search query with then --gen flag"), esc defer()
    await @prompt_new_passphrase esc defer passphrase 
    log.debug "+ generating public/private keypair"
    await KeyManager.generate { passphrase }, esc defer @keymanager
    log.debug "- generated"
    log.debug "+ loading public key"
    await @keymanager.load_public esc defer key
    log.debug "- loaded public key"
    cb null, key

  #----------

  run : (cb) ->
    esc = make_esc cb, "run"
    if @argv.gen
      await @do_key_gen esc defer @key
    else
      await key_select {username: env().get_username(), query : @argv.search }, esc defer @key
      await @load_key_manager defer() if @argv.push_secret
    await session.login esc defer()
    await @sign esc defer()
    await @package_secret_key esc defer() if (@argv.push_secret and @keymanager?)
    await @push esc defer()
    log.info "success!"
    cb null

##=======================================================================

