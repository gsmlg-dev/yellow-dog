# Yellow Dog DNS

![Yellow Dog DNS](./priv/yellow_dog.png)


Yellow Dog DNS is a distribute DNS Server written by erlang/elixir.


## Architecture


## Howto

Run

```shell
mix run --no-halt
```

Benchmark

```shell
dnsperf -n 100000 -d t.txt -s 127.0.0.1 -p 5454

cat t.txt
  www.turku.fi A
  www.helsinki.fi A
```
