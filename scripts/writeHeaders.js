const fs = require("fs").promises;
const path = require("path");

const walkTree = async function* ({ dir, predicate }) {
  const files = await fs.readdir(dir);

  for (const file of files) {
    const filePath = path.join(dir, file);
    const stat = await fs.stat(filePath);

    if (stat.isDirectory()) {
      yield* walkTree({ dir: filePath, predicate });
    } else if (predicate(file)) {
      yield filePath;
    }
  }
};

const headers = async ({ dir, header, predicate }) => {
  for await (const filePath of walkTree({ dir, predicate })) {
    const start = process.hrtime();

    const data = Buffer.from(await fs.readFile(filePath));

    if (data.indexOf(header) === 0) continue;

    const fd = await fs.open(filePath, "w+");

    await fd.write(header, 0, header.length, 0);
    await fd.write(data, 0, data.length, header.length);
    await fd.close();

    const [, ns] = process.hrtime(start);
    const ms = ns / 1_000_000;

    console.info(`${filePath} ${ms}ms`);
  }
};

const header = `// SPDX-License-Identifier: BUSL-1.1

/**                                                     
*  █████╗ ███████╗████████╗ █████╗ ██████╗ ██╗ █████╗ 
* ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██║██╔══██╗
* ███████║███████╗   ██║   ███████║██████╔╝██║███████║
* ██╔══██║╚════██║   ██║   ██╔══██║██╔══██╗██║██╔══██║
* ██║  ██║███████║   ██║   ██║  ██║██║  ██║██║██║  ██║
* ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
*
* Astaria Labs, Inc
*/\n\n`;

headers({
  dir: "./src",
  header,
  predicate: (filePath) => /\.sol$/.test(filePath),
});

module.exports = headers;
