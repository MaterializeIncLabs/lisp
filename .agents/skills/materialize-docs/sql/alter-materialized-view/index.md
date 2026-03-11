# ALTER MATERIALIZED VIEW
`ALTER MATERIALIZED VIEW` changes the parameters of a materialized view.
Use `ALTER MATERIALIZED VIEW` to:

- Rename a materialized view.
- Change owner of a materialized view.
- Change retain history configuration for the materialized view.










- Replace a materialized view. (*Public preview*)





## Syntax


**Rename:**

### Rename

To rename a materialized view:



```mzsql
ALTER MATERIALIZED VIEW <name> RENAME TO <new_name>;

```

| Syntax element | Description |
| --- | --- |
| `<name>` | The current name of the materialized view you want to alter.  |
| `<new_name>` | The new name of the materialized view.  |
See also [Renaming restrictions](/sql/identifiers/#renaming-restrictions).



**Change owner:**

### Change owner

To change the owner of a materialized view:



```mzsql
ALTER MATERIALIZED VIEW <name> OWNER TO <new_owner_role>;

```

| Syntax element | Description |
| --- | --- |
| `<name>` | The name of the materialized view you want to change ownership of.  |
| `<new_owner_role>` | The new owner of the materialized view.  |
To change the owner of a materialized view, you must be the owner of the materialized view and have
membership in the `<new_owner_role>`. See also [Privileges](#privileges).



**(Re)Set retain history config:**

### (Re)Set retain history config

To set the retention history for a materialized view:



```mzsql
ALTER MATERIALIZED VIEW <name> SET (RETAIN HISTORY [=] FOR <retention_period>);

```

| Syntax element | Description |
| --- | --- |
| `<name>` | The name of the materialized view you want to alter.  |
| `<retention_period>` | ***Private preview.** This option has known performance or stability issues and is under active development.* Duration for which Materialize retains historical data, which is useful to implement [durable subscriptions](/transform-data/patterns/durable-subscriptions/#history-retention-period). Accepts positive [interval](/sql/types/interval/) values (e.g. `'1hr'`). Default: `1s`.  |


To reset the retention history to the default for a materialized view:



```mzsql
ALTER MATERIALIZED VIEW <name> RESET (RETAIN HISTORY);

```

| Syntax element | Description |
| --- | --- |
| `<name>` | The name of the materialized view you want to alter.  |











**Replace materialized view:**

### Replace materialized view

> **Public Preview:** This feature is in public preview.

To replace an existing materialized view in-place with a replacement
materialized view:



```mzsql
ALTER MATERIALIZED VIEW <name> APPLY REPLACEMENT <replacement_materialized_view>;

```

| Syntax element | Description |
| --- | --- |
| `<name>` | The name of the materialized view to replace.  |
| `<replacement_materialized_view>` | The name of a replacement materialized view specifically created for the target materialized view. See [`CREATE REPLACEMENT MATERIALIZED VIEW <replacement_view>...FOR <name>...`](/sql/create-materialized-view).  |

















## Details

### Replacing a materialized view

> **Public Preview:** This feature is in public preview.

You can use [`CREATE REPLACEMENT MATERIALIZED
VIEW`](/sql/create-materialized-view/) with [`ALTER MATERIALIZED VIEW ... APPLY
REPLACEMENT`](/sql/alter-materialized-view) to replace materialized views
in-place without recreating dependent objects or incurring downtime.

<p>When replacing a materialized view, the operation:</p>
<ul>
<li>
<p>Replaces the materialized view&rsquo;s definition with that of the replacement
view and drops the replacement view at the same time.</p>
</li>
<li>
<p>Emits a diff representing the changes between the old and new output.</p>
</li>
</ul>


See [Recommended checks before replacing a
view](/sql/alter-materialized-view/#recommended-checks-before-replacing-a-view).

#### Recommended checks before replacing a view

<p>Before applying, verify that the replacement materialized view is hydrated
to avoid downtime:</p>
<div class="highlight"><pre tabindex="0" class="chroma"><code class="language-mzsql" data-lang="mzsql"><span class="line"><span class="cl"><span class="k">SELECT</span>
</span></span><span class="line"><span class="cl">   <span class="n">mv</span><span class="mf">.</span><span class="k">name</span><span class="p">,</span>
</span></span><span class="line"><span class="cl">   <span class="n">h</span><span class="mf">.</span><span class="n">hydrated</span>
</span></span><span class="line"><span class="cl"><span class="k">FROM</span> <span class="n">mz_catalog</span><span class="mf">.</span><span class="n">mz_materialized_views</span> <span class="k">AS</span> <span class="n">mv</span>
</span></span><span class="line"><span class="cl"><span class="k">JOIN</span> <span class="n">mz_internal</span><span class="mf">.</span><span class="n">mz_hydration_statuses</span> <span class="k">AS</span> <span class="n">h</span> <span class="k">ON</span> <span class="p">(</span><span class="n">mv</span><span class="mf">.</span><span class="k">id</span> <span class="o">=</span> <span class="n">h</span><span class="mf">.</span><span class="n">object_id</span><span class="p">)</span>
</span></span><span class="line"><span class="cl"><span class="k">WHERE</span> <span class="n">mv</span><span class="mf">.</span><span class="k">name</span> <span class="o">=</span> <span class="s1">&#39;&lt;replacement_view&gt;&#39;</span><span class="p">;</span>
</span></span></code></pre></div>

#### Considerations

When applying the replacement, dependent objects must process the diff
emitted by the operation. Depending on the size of the changes, this may
cause temporary CPU and memory spikes.

#### Troubleshooting

<p><strong>Issue:</strong> Command does not return.</p>
<p><strong>Common cause:</strong> The original materialized view is lagging behind the replacement. If
the original is lagging behind the replacement, the command waits for the
original view to catch up.</p>
<p><strong>Action:</strong> Cancel the command and check whether the original materialized view is
lagging behind the replacement.</p>
<p>To check whether the original materialized view is lagging behind the replacement, run
the following query to check their write frontiers, substituting the names
of your original and replacement materialized views.</p>
<div class="highlight"><pre tabindex="0" class="chroma"><code class="language-mzsql" data-lang="mzsql"><span class="line"><span class="cl"><span class="k">SELECT</span> <span class="n">o</span><span class="mf">.</span><span class="k">name</span><span class="p">,</span> <span class="n">f</span><span class="mf">.</span><span class="n">write_frontier</span>
</span></span><span class="line"><span class="cl"><span class="k">FROM</span> <span class="n">mz_objects</span> <span class="n">o</span><span class="p">,</span> <span class="n">mz_cluster_replica_frontiers</span> <span class="n">f</span>
</span></span><span class="line"><span class="cl"><span class="k">WHERE</span> <span class="n">o</span><span class="mf">.</span><span class="k">name</span> <span class="k">in</span> <span class="p">(</span><span class="s1">&#39;&lt;view&gt;&#39;</span><span class="p">,</span> <span class="s1">&#39;&lt;view_replacement&gt;&#39;</span><span class="p">)</span>
</span></span><span class="line"><span class="cl"><span class="k">AND</span> <span class="n">f</span><span class="mf">.</span><span class="n">object_id</span> <span class="o">=</span> <span class="n">o</span><span class="mf">.</span><span class="k">id</span><span class="p">;</span>
</span></span></code></pre></div><p>If the original materialized view is behind, rerun the query to check the progress of the
original materialized view. If the rate of advancement suggests that catch
up will take an extended period of time, it is recommended to drop the
replacement view.</p>






## Privileges

The privileges required to execute this statement are:

- Ownership of the materialized view.
- In addition, to change owners:
  - Role membership in `new_owner`.
  - `CREATE` privileges on the containing schema if the materialized view is
  namespaced by a schema.










- In addition, to apply a replacement:
  - Ownership of the replacement materialized view.









## Examples

### Replace a materialized view

> **Public Preview:** This feature is in public preview.

A replacement materialized view can only be applied to the target materialized
view specified in the `FOR` clause of the [`CREATE REPLACEMENT MATERIALIZED
VIEW`](/sql/create-materialized-view/) statement.

#### Example Prerequisite

The following example creates a replacement materialized view
`winning_bids_replacement` for the `winning_bids` materialized view. The
replacement view specifies a different filter `mz_now() > a.end_time` than
the existing view `mz_now() >= a.end_time`.
```mzsql
CREATE REPLACEMENT MATERIALIZED VIEW winning_bids_replacement
FOR winning_bids AS
SELECT DISTINCT ON (a.id) b.*, a.item, a.seller
FROM auctions AS a
JOIN bids AS b
  ON a.id = b.auction_id
WHERE b.bid_time < a.end_time
  AND mz_now() > a.end_time
ORDER BY a.id,
  b.amount DESC,
  b.bid_time,
  b.buyer;

```

The replacement view hydrates in the background.

#### Apply the replacement

Assume that `winning_bids_replacement` is hydrated to avoid downtime (see
[Recommended checks before replacing a
view](/sql/alter-materialized-view/#recommended-checks-before-replacing-a-view)
for details).

The following example replaces the `winning_bids` materialized view
with `winning_bids_replacement`:
```mzsql
ALTER MATERIALIZED VIEW winning_bids
APPLY REPLACEMENT winning_bids_replacement;

```

For a step-by-step tutorial on replacing a materialized view, see [Replace
materialized views
guide](/transform-data/updating-materialized-views/replace-materialized-view/).





## Related pages

- [`CREATE MATERIALIZED VIEW`](/sql/create-materialized-view)
- [`SHOW MATERIALIZED VIEWS`](/sql/show-materialized-views)
- [`SHOW CREATE MATERIALIZED VIEW`](/sql/show-create-materialized-view)
- [`DROP MATERIALIZED VIEW`](/sql/drop-materialized-view)
