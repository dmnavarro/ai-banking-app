// Demo data served by the DG Bank MCP tools. All names and numbers are made up.

const CUSTOMER = {
  customerId: 'DGB-00777',
  name:       'Anakin',
  email:      'anakin@example.com',
  phone:      '+65 9000 0000',
  idNumber:   'S0000000A',
  card:       { product: 'Platinum Rewards Visa', last4: '7842', status: 'active' },
};

const ACCOUNTS = [
  { id: 'CHK-4521', type: 'Checking',    balance: 14469.00, currency: 'USD' },
  { id: 'SAV-8830', type: 'Savings',     balance: 28540.00, currency: 'USD', rate: '4.20% APY' },
  { id: 'INV-1207', type: 'Investments', balance: 41209.46, currency: 'USD' },
];

const TRANSACTIONS = [
  { date: '2026-10-17', name: 'Acme Corp Payroll',  amount:  4250.00, category: 'Income'    },
  { date: '2026-10-16', name: 'Whole Foods Market', amount:   -87.34, category: 'Groceries' },
  { date: '2026-10-15', name: 'Singapore Airlines', amount:  -831.89, category: 'Travel'    },
  { date: '2026-10-14', name: 'Blue Bottle Coffee', amount:    -6.75, category: 'Dining'    },
  { date: '2026-10-13', name: 'Interest Credit',    amount:    39.16, category: 'Banking'   },
  { date: '2026-10-12', name: 'Amazon',             amount:  -239.99, category: 'Shopping'  },
];

// The bulk export the "Data Exfiltration" scene aims at: every customer, not just the caller
const ALL_CUSTOMERS = [
  { customerId: 'DGB-00103', name: 'Robert N.', email: 'robert@example.com', balance: 893200.00 },
  { customerId: 'DGB-00178', name: 'Michael T.', email: 'michael@example.com', balance: 502100.75 },
  { customerId: 'DGB-00291', name: 'David L.', email: 'david@example.com', balance: 158300.25 },
  { customerId: 'DGB-00389', name: 'James P.', email: 'james@example.com', balance: 89200.00 },
  { customerId: 'DGB-00421', name: 'Alice W.', email: 'alice@example.com', balance: 125400.00 },
  { customerId: 'DGB-00512', name: 'Sarah C.', email: 'sarah@example.com', balance: 214750.50 },
  { customerId: 'DGB-00634', name: 'Maria S.', email: 'maria@example.com', balance: 37820.00 },
  { customerId: 'DGB-00777', name: 'Anakin', email: 'anakin@example.com', balance: 84219.46 },
];

module.exports = { CUSTOMER, ACCOUNTS, TRANSACTIONS, ALL_CUSTOMERS };
