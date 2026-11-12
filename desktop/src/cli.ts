const usage = `Usage: hippo <command> [options]

Commands:
  (none yet)
`;

type Command = (args: string[]) => Promise<number | void> | number | void;
const commands: Record<string, Command> = {};

const [name, ...args] = process.argv.slice(2);
const run = name === undefined ? undefined : commands[name];
if (!run) {
  process.stderr.write(usage);
  process.exit(2);
}
process.exit((await run(args)) ?? 0);
