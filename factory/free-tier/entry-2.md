### 2. Every preview gets its own database branch

- **Set:** on the database's connection to the project, `deployments: {required: true, actions: [{slug: "Neon", environments: ["preview"]}]}`. In the dashboard: "Require Active Resource Before Deploy" on, and "Create Database Branch For Deployment → Preview".
- **Protects:** production data, not a quota. Sharing one database would mean a pull request's migrations run on live data before anyone has reviewed them, its tests write into real records, and two open pull requests fight over one schema. `ARCHITECTURE.md` (Environments) has the full reasoning.
- **Costs:** one of the 9 branch slots per pull request (hence [entry 1](entry-1.md)), and 4.5 seconds added to each preview build (measured). Compute is small: a preview's database wakes for its tests and sleeps after 5 minutes, about 0.02 compute-hours per pull request, so 200 pull requests use about 4 of the 100 hours.
- **Automated:** yes, by `database.sh`. The field is in neither Vercel's CLI nor its public API spec; it was found by comparing the connection record before and after ticking the boxes by hand.
