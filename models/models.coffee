Mongo = require('./mongo').Mongo
http = require('./http')
sys = require 'sys'
crypto = require 'crypto'
require '../public/javascripts/Math.uuid'
nko = {}

md5 = (str) ->
  hash = crypto.createHash 'md5'
  hash.update str
  hash.digest 'hex'

validEmail = (email) ->
  /^[a-zA-Z0-9+._-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$/.test email

escapeURL = require('querystring').escape
parseURL = require('url').parse

class Team
  serializable_attributes: ['score']

  build: (options) ->
    @name = options?.name or ''
    @createdAt = new Date()
    @application = options?.application or ''
    @description = options?.description or ''
    @colophon = options?.colophon or ''
    @link = options?.link or ''
    @url = options?.url or ''
    @joyentCode = options?.joyentCode or ''
    @lastDeployedTo = options?.lastDeployedTo or ''
    @lastDeployedAt = options?.lastDeployedAt
    @deployHeads = options?.deployHeads or []

  constructor: (options, fn) ->
    @build options
    @token = Math.uuid()
    @setMembers options?.emails, fn

  # TODO DRY
  authKey: ->
    @id() + ':' + @token

  hasMember: (member) ->
    return false unless member?
    _.include _.invoke(@members, 'id'), member.id()

  emails: ->
    _.pluck @members, 'email'

  validate: ->
    errors = []
    errors.push 'Must have team name' unless @name
    errors.push 'Team needs at least one member' unless @members?.length
    errors.concat _.compact _.flatten [member.validate() for member in @members]

  beforeSave: (fn) ->
    @generateSlug =>
      @generateDeploySlugs()
      threads = @members.length
      return fn() unless threads
      for member in @members
        member.save (error, res) ->
          fn() if --threads is 0

  beforeInstantiate: (fn) ->
    query = { _id: { $in: _.pluck @members, '_id' }}
    Person.all query, (error, members) =>
      @members = members
      @invited = _.select @members, (m) -> m.name == ''
      fn()

  setMembers: (emails, fn) ->
    emails = _.compact emails or []
    @members = or []
    oldEmails = @emails()

    keepEmails = _.intersect emails, oldEmails
    @members = _.select @members, (m) ->
      _.include keepEmails, m.email

    newEmails = _.without emails, oldEmails...
    threads = newEmails.length
    return process.nextTick fn unless threads

    for email in newEmails
      Person.firstOrNew { email: email }, (error, member) =>
        @members.push member
        member.type or= 'Participant'
        member.inviteTo this, ->
          fn() if --threads is 0

  generateSlug: (fn, attempt) ->
    @slug = attempt || @name.toLowerCase().replace(/\W+/g, '-').replace(/^-|-$/, '')
    Team.fromParam @slug, (error, existing) =>
      if !existing? or existing.id() == @id()
        fn()  # no conflicts
      else
        @generateSlug fn, @slug + '-'  # try with another -

  generateDeploySlugs: ->
    @joyentSlug or= @slug.replace(/^(\d)/, 'ko-$1').replace(/_/g, '-').substring(0, 30)
    @herokuSlug or= 'nko-' + @slug.replace(/_/g, '-').substring(0, 26)
nko.Team = Team

class ScoreCalculator
  calculate: (fn) ->
    @select =>
      @merge()
      @zero()
      @calcConfirmed()
      @average()
      @calcFinal()
      @calcPopularity()
      @calcOverall()
      fn @scores

  select: (fn) ->
    threads = 4
    @where {}, (error, all) =>
      @all = all
      fn() if --threads is 0
    @where { confirmed: false }, (error, unconfirmed) =>
      @unconfirmed = unconfirmed
      fn() if --threads is 0
    @where { confirmed: true }, (error, confirmed) =>
      @confirmed = confirmed
      fn() if --threads is 0

    Person.all { type: 'Judge' }, (error, judges) =>
      judge_ids = _.pluck(judges, '_id');
      @where { 'person._id': { $in: judge_ids }}, (error, judged) =>
        @judged = judged
        fn() if --threads is 0

  merge: ->
    @scores = {}
    for type in @types
      for score in this[type]
        @scores[score['team._id']] ||= {}
        @scores[score['team._id']][type] = score

  zero: ->
    for k, score of @scores
      for type in @types
        score[type] ?= {}
        delete score[type]['team._id']
        for dimension in @dimensions
          score[type][dimension] ?= 0

  calcConfirmed: ->
    for k, score of @scores
      for dimension in @dimensions
        score.confirmed[dimension] -= score.judged[dimension]

  average: ->
    for k, score of @scores
      for type in @types
        for dimension in @dimensions[0..3]
          score[type][dimension] = score[type][dimension] / score[type].popularity

  calcFinal: ->
    for k, score of @scores
      score.final = {}
      for dimension in @dimensions[0..3]
        score.final[dimension] = (score.confirmed[dimension] || 0) + (score.judged[dimension] || 0)

  calcPopularity: (scores) ->
    popularities = for k, score of @scores
      { key: k, popularity: (score.confirmed?.popularity || 0) }
    popularities.sort (a, b) -> b.popularity - a.popularity

    rank = popularities.length
    for popularity in popularities
      score = @scores[popularity.key]
      score.final.popularity = 2 + 8 * (rank-- / popularities.length)

  calcOverall: ->
    for k, score of @scores
      score.overall = 0
      for dimension in @dimensions
        score.overall += score.final[dimension]

  where: (cond, fn) ->
    initial = {}
    for k in @dimensions
      initial[k] = 0
    Vote.group {
      cond: cond
      keys: ['team._id']
      initial: initial
      reduce: (row, memo) ->
        memo.popularity += 1
        # must be hard coded (passed as a string to mongo)
        for dimension in ['utility', 'design', 'innovation', 'completeness']
          memo[dimension] += parseInt row[dimension]
      }, fn

  dimensions: ['utility', 'design', 'innovation', 'completeness', 'popularity']
  types: ['unconfirmed', 'confirmed', 'judged', 'all']

_.extend ScoreCalculator, {
  calculate: (fn) ->
    (new ScoreCalculator).calculate fn
}

nko.ScoreCalculator = ScoreCalculator

class Person
  constructor: (options) ->
    @name = options?.name or ''
    @email = options?.email or ''

    @link = options?.link or ''
    @github = options?.github or ''
    @heroku = options?.heroku or ''
    @joyent = options?.joyent or ''

    @password = @randomPassword()
    @new_password = true
    @confirmed = options?.confirmed or false
    @confirmKey = Math.uuid()

    @type = options?.type # 'Judge', 'Voter', 'Participant'

    @description = options?.description or ''
    @signature = options?.signature or ''

    @token = Math.uuid()
    @calculateHashes()

  admin: ->
    @confirmed and /\@nodeknockout\.com$/.test(@email)

  displayName: ->
    @name or @email.replace(/\@.*$/,'')

  firstName: ->
    @displayName().split(' ')[0]

  resetPassword: (fn) ->
    @password = @randomPassword()
    @new_password = true
    @calculateHashes()
    @save (error, res) =>
      # TODO get this into a view
      @sendEmail "Password reset for Node.js Knockout", """
        Hi,

        You (or somebody like you) reset the password for this email address.

        Here are your new credentials:
        email: #{@email}
        password: #{@password}

        Thanks!
        The Node.js Knockout Organizers
        """, fn

  inviteTo: (team, fn) ->
    @sendEmail "You've been invited to Node.js Knockout", """
      Hi,

      You've been invited to the #{team.name} Node.js Knockout team!

      Here are your credentials:
      email: #{@email}
      #{if @password then 'password: ' + @password else 'and whatever password you already set'}

      You still need to complete your registration.
      Please sign in at: http://nodeknockout.com/login?email=#{escapeURL @email}&password=#{@password} to do so.


      Thanks!
      The Node.js Knockout Organizers

      Node.js Knockout is a 48-hour programming contest using node.js from Aug 28-29, 2010.
      """, fn

  welcomeVoter: (fn) ->
    # TODO get this into a view
    @sendEmail "Thanks for voting in Node.js Knockout", """
      Hi,

      You (or somebody like you) used this email address to vote in Node.js Knockout, so we created an account for you.

      Here are your credentials:
      email: #{@email}
      password: #{@password}

      Please sign in to confirm your votes: http://nodeknockout.com/login?email=#{escapeURL @email}&password=#{@password}

      Thanks!
      The Node.js Knockout Organizers
      http://nodeknockout.com/
      """, fn

  notifyAboutReply: (vote, reply, fn) ->
    @sendEmail "#{reply.person.name} Replied to your Node.js Knockout Vote", """
      Hi,

      #{reply.person.name} replied to #{if @id() is vote.person.id() then 'your' else 'a'} vote for #{vote.team.name}, writing:

      "#{reply.body}"

      You can respond at: http://nodeknockout.com/teams/#{vote.team.toParam()}##{vote.id()}

      Thanks!
      The Node.js Knockout Organizers
      http://nodeknockout.com/
      """

  sendConfirmKey: (fn) ->
    @sendEmail "Confirm your Node.js Knockout Email", """
      Hi,

      You (or somebody like you) requested we resend your Node.js Knockout email confirmation code.

      Your confirmaton code is: #{@confirmKey}

      You can confirm your email at: http://nodeknockout.com/people/#{@toParam()}/confirm?confirmKey=#{@confirmKey}

      Thanks!
      The Node.js Knockout Organizers
      http://nodeknockout.com/
      """, fn

  sendEmail: (subject, message, fn) ->
    http.post 'http://www.postalgone.com/mail',
      { sender: '"Node.js Knockout" <mail@nodeknockout.com>',
      from: 'all@nodeknockout.com',
      to: @email,
      subject: subject,
      body: message }, (error, body, response) ->
        fn()

  confirmVotes: (fn) ->
    return fn() if Date.now() > Date.UTC(2010, 8, 3, 7, 0, 0)
    Vote.updateAll { 'person._id': @_id, confirmed: false }, { $set: { confirmed: true }}, fn

  loadTeams: (fn) ->
    Team.all { 'members._id': @_id }, (error, teams) =>
      fn error if error?
      @teams = teams or []
      fn(error, @teams)

  loadVotes: (fn) ->
    Vote.all { 'person._id': @_id }, (error, votes) =>
      fn error if error?
      @votes = votes or []
      Vote.loadTeams votes, (error, teams) =>
        fn error if error?
        fn null, @votes

  authKey: ->
    @id() + ':' + @token

  logout: (fn) ->
    @token = null
    @save fn

  validate: ->
    ['Invalid email address'] unless validEmail @email

  beforeSave: (fn) ->
    @email = @email?.trim()?.toLowerCase()
    @calculateHashes()
    fn()

  setPassword: (password) ->
    # overwrite the default password
    @passwordHash = md5 password
    @password = ''

  calculateHashes: ->
    @emailHash = md5 @email
    @passwordHash = md5 @password if @password

  # http://e-huned.com/2008/10/13/random-pronounceable-strings-in-ruby/
  randomPassword: ->
    alphabet = 'abcdefghijklmnopqrstuvwxyz'.split('')
    vowels = 'aeiou'.split('')
    consonants = _.without alphabet, vowels...
    syllables = for i in [0..2]
      consonants[Math.floor consonants.length * Math.random()] +
      vowels[Math.floor vowels.length * Math.random()] +
      alphabet[Math.floor alphabet.length * Math.random()]
    syllables.join ''

  login: (fn) ->
    @token = Math.uuid()

    @confirmed ?= true # grandfather old people in
    if @new_password or @verifiedConfirmKey
      confirm_votes = true
      @confirmed = true
      @confirmKey = Math.uuid()
      @new_password = false
      delete @verifiedConfirmKey

    @save (errors, resp) =>
      if confirm_votes
        # TODO flash "your votes have been confirmed"
        @confirmVotes (errors) =>
          fn errors, this
      else
        fn null, this

_.extend Person, {
  login: (credentials, fn) ->
    return fn ['Invalid email address'] unless validEmail credentials.email
    @first { email: credentials.email.trim().toLowerCase() }, (error, person) ->
      return fn ['Unknown email'] unless person?
      return fn ['Invalid password'] unless person.passwordHash is md5 credentials.password
      person.login fn

  firstByAuthKey: (authKey, fn) ->
    [id, token] = authKey.split ':' if authKey?
    return fn null, null unless id and token

    query = Mongo.queryify id
    query.token = token
    @first query, fn
}

nko.Person = Person

class Vote
  updateable_attributes: ['utility', 'design', 'innovation', 'completeness', 'comment']

  constructor: (options, request) ->
    @team = options?.team

    @utility = parseInt options?.utility
    @design = parseInt options?.design
    @innovation = parseInt options?.innovation
    @completeness = parseInt options?.completeness

    @comment = options?.comment
    @person = options?.person
    @email = options?.email?.trim()?.toLowerCase() || @person?.email
    @confirmed = !! @person?.confirmed

    @remoteAddress = request?.socket?.remoteAddress
    @remotePort = request?.socket?.remotePort
    @userAgent = request?.headers?['user-agent']
    @referer = request?.headers?['referer']
    @accept = request?.headers?['accept']

    @requestAt = options?.requestAt
    @renderAt = options?.renderAt
    @hoverAt = options?.hoverAt
    @responseAt = options?.responseAt

    @createdAt = @updatedAt = new Date()

  beforeSave: (fn) ->
    if !@person?
      Person.firstOrNew { email: @email }, (error, voter) =>
        return fn ['Unauthorized'] unless voter.isNew()
        return fn ['"+" not allowed in voter email address'] if @email.split('@')[0].match /\+/
        @person = voter
        @person.type = 'Voter'
        @person.save (error, person) =>
          return fn error if error?
          @person.welcomeVoter fn
    else
      @confirmed = !! @person?.confirmed
      if @isNew()
        @checkDuplicate fn
      else
        @updatedAt = new Date()
        fn()

  checkDuplicate: (fn) ->
    Vote.firstByTeamAndPerson @team, @person, (errors, existing) =>
      return fn errors if errors?.length
      return fn ["Duplicate"] if existing?
      fn()

  beforeInstantiate: (fn) ->
    Person.first { _id: @person._id }, (error, voter) =>
      @person = voter
      Reply.all { 'vote._id': @_id }, { sort: [['createdAt', 1]]}, (error, replies) =>
        @replies = replies || []
        fn()

  instantiateReplyers: ->
    pool = _.inject @team.members, {}, ((memo, person) -> memo[person.id()] = person; memo)
    pool[@person.id()] = @person
    @replies ||= []
    for reply in @replies
      reply.person = pool[reply.person.id()]

  notifyPeopleAboutReply: (reply) ->
    for m in @team.members when m.id() isnt reply.person.id()
      m.notifyAboutReply this, reply, ->
    if reply.person.id() isnt @person.id()
      @person.notifyAboutReply this, reply, ->

  validate: ->
    errors = []
    errors.push 'Invalid vote. Ballot stuffing attempt?' if @isNew() and @looksFishy()
    for dimension in [ 'Utility', 'Design', 'Innovation', 'Completeness' ]
      errors.push "#{dimension} should be between 1 and 5 stars" unless 1 <= this[dimension.toLowerCase()] <= 5
    errors.push 'Invalid email address' unless validEmail @email
    errors

  looksFishy: ->
    (!@userAgent or
      !(parseURL(@referer).hostname in ['nodeknockout.com', 'localhost', 'knockout.no.de', 'pulp.local']) or
      !(@requestAt < @responseAt) or !(@renderAt < @hoverAt))

_.extend Vote, {
  firstByTeamAndPerson: (team, person, fn) ->
    Vote.first { 'team._id': team._id, 'person._id': person._id }, fn

  loadTeams: (votes, fn) ->
    teamIds = _(votes).chain().pluck('team').pluck('_id').value()
    Team.all { _id: { $in: teamIds }}, (error, teams) ->
      fn error if error?
      # TODO gross
      teamHash = _.inject teams, {}, ((memo, team) -> memo[team._id.id] = team; memo)
      for vote in votes
        vote.team = teamHash[vote.team._id.id]
        vote.instantiateReplyers()
      fn null, teams
}

nko.Vote = Vote

class Reply
  constructor: (options) ->
    @person = options?.person
    @vote = options?.vote
    @body = options.body || ''
    @createdAt = @updatedAt = new Date()

  validate: ->
    ['Reply cannot be blank'] unless @body
nko.Reply = Reply

Mongo.blessAll nko
nko.Mongo = Mongo

Team::toParam = -> @slug
Team.fromParam = (id, options, fn) ->
  if id.length == 24
    @first { '$or': [ { slug: id }, Mongo.queryify(id) ] }, options, fn
  else
    @first { slug: id }, options, fn

_.extend exports, nko
