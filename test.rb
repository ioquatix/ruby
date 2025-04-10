# Consume most of the VM stack:
def recurse(n = 1250, &block)
  if n > 0
    recurse(n - 1, &block)
  else
    yield
  end
end

fiber = Fiber.new do
  recurse do
    # Consume more than the default stack:
    Fiber.consume_stack(524288 + 131072 - 1024*10)
  end
end

fiber.resume
