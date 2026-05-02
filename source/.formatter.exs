# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  line_length: 79,
  locals_without_parens: [
    embed_templates: 1,
    get: 3,
    live: 2,
    pipe_through: 1,
    plug: 1,
    plug: 2,
    post: 3,
    socket: 3
  ]
]
