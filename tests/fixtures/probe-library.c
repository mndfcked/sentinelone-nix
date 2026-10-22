extern int host_dependency_value(void);
extern int transitive_value(void);
extern int vendor_value(void);

int fixture_value(void) {
  return host_dependency_value() + transitive_value() + vendor_value();
}
