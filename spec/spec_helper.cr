require "spec"
require "../src/cordon"

private def set_env(key : String, value : String?) : Nil
  if value
    ENV[key] = value
  else
    ENV.delete(key)
  end
end

# Sets *vars* (nil deletes) for the duration of the block, then restores them.
def with_env(vars, &)
  saved = vars.keys.to_h { |key| {key, ENV[key]?} }
  begin
    vars.each { |key, value| set_env(key, value) }
    yield
  ensure
    saved.each { |key, value| set_env(key, value) }
  end
end
