[
  # find-callers can only fail with :bad_target today, but the catch-all
  # keeps a future error from ProjectRewrite.new/1 a readable message
  # instead of a CaseClauseError.
  {"lib/adze/cli.ex", :pattern_match_cov}
]
